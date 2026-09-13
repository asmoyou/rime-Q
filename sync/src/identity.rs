use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use rand::{rngs::OsRng, RngCore};
use sha2::{Digest, Sha256};
use std::{fs, path::Path};
use zeroize::Zeroize;

pub fn encode(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}
pub fn decode(text: &str) -> Result<Vec<u8>> {
    Ok(URL_SAFE_NO_PAD.decode(text)?)
}
pub fn random() -> String {
    let mut b = [0u8; 32];
    OsRng.fill_bytes(&mut b);
    encode(&b)
}
pub fn digest(bytes: &[u8]) -> String {
    encode(&Sha256::digest(bytes))
}

pub struct Identity {
    key: SigningKey,
}
impl Identity {
    pub fn replace(root: &Path, isolated: bool) -> Result<Self> {
        let identity = Self::generate();
        let mut secret = zeroize::Zeroizing::new(identity.key.to_bytes());
        let saved = zeroize::Zeroizing::new(if isolated {
            secret.to_vec()
        } else {
            protect(root, secret.as_ref())?
        });
        atomic_write(&root.join("identity.key"), &saved)?;
        secret.zeroize();
        Ok(identity)
    }
    pub fn generate() -> Self {
        Self {
            key: SigningKey::generate(&mut OsRng),
        }
    }
    pub fn id(&self) -> String {
        encode(self.key.verifying_key().as_bytes())
    }
    pub fn sign(&self, bytes: &[u8]) -> String {
        encode(&self.key.sign(bytes).to_bytes())
    }
    pub fn load(root: &Path, isolated: bool) -> Result<Self> {
        private_directory(root)?;
        let path = root.join("identity.key");
        let marker = root.join("isolated-test-only");
        if isolated {
            ensure!(
                marker.exists() || (!path.exists() && !root.join("state.sqlite").exists()),
                "isolated mode requires a new test directory"
            );
            if !marker.exists() {
                atomic_write(&marker, b"Synthetic test data only\n")?;
            }
        } else {
            ensure!(
                !marker.exists(),
                "test identities cannot be used for production sync"
            );
        }
        let mut secret = zeroize::Zeroizing::new(if path.exists() {
            let saved = zeroize::Zeroizing::new(fs::read(&path)?);
            if isolated {
                saved.to_vec()
            } else {
                unprotect(root, &saved)?
            }
        } else {
            let key = zeroize::Zeroizing::new(Self::generate().key.to_bytes().to_vec());
            let saved = zeroize::Zeroizing::new(if isolated {
                key.to_vec()
            } else {
                protect(root, &key)?
            });
            atomic_write(&path, &saved)?;
            key.to_vec()
        });
        ensure!(secret.len() == 32, "invalid device identity");
        let key = SigningKey::from_bytes(secret.as_slice().try_into()?);
        secret.zeroize();
        Ok(Self { key })
    }
}

pub fn verify(id: &str, bytes: &[u8], signature: &str) -> Result<()> {
    let key = decode(id)?;
    let signature = decode(signature)?;
    VerifyingKey::from_bytes(key.as_slice().try_into()?)?
        .verify_strict(bytes, &Signature::from_slice(&signature)?)
        .context("signature rejected")
}

pub fn private_directory(root: &Path) -> Result<()> {
    fs::create_dir_all(root)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(root, fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let output = std::process::Command::new("whoami.exe")
            .args(["/user", "/fo", "csv", "/nh"])
            .creation_flags(0x08000000)
            .output()?;
        ensure!(output.status.success(), "cannot resolve user identity");
        let value = String::from_utf8_lossy(&output.stdout);
        let sid = value
            .split(['"', ',', '\r', '\n'])
            .find(|s| s.starts_with("S-1-"))
            .context("missing user SID")?;
        ensure!(
            sid.bytes()
                .all(|b| b.is_ascii_digit() || b == b'-' || b == b'S'),
            "invalid user SID"
        );
        let status = std::process::Command::new("icacls.exe")
            .arg(root)
            .args([
                "/inheritance:r",
                "/grant:r",
                &format!("*{sid}:(OI)(CI)F"),
                "*S-1-5-18:(OI)(CI)F",
            ])
            .creation_flags(0x08000000)
            .output()?;
        ensure!(
            status.status.success(),
            "cannot restrict sync directory permissions"
        );
    }
    Ok(())
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let temporary = path.with_extension(format!("{}.tmp", random()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| -> Result<()> {
        let mut f = options.open(&temporary)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        drop(f);
        #[cfg(windows)]
        {
            // MoveFileExW is an atomic replacement on the same volume.
            use std::os::windows::ffi::OsStrExt;
            use windows_sys::Win32::Storage::FileSystem::{
                MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
            };
            let a: Vec<_> = temporary.as_os_str().encode_wide().chain(Some(0)).collect();
            let b: Vec<_> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            ensure!(
                unsafe {
                    MoveFileExW(
                        a.as_ptr(),
                        b.as_ptr(),
                        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
                    )
                } != 0,
                "atomic replacement failed"
            );
        }
        #[cfg(not(windows))]
        {
            fs::rename(&temporary, path)?;
            fs::File::open(path.parent().context("missing parent")?)?.sync_all()?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(windows)]
fn crypt(bytes: &[u8], encrypt: bool) -> Result<Vec<u8>> {
    use windows_sys::Win32::{Foundation::LocalFree, Security::Cryptography::*};
    let source = CRYPT_INTEGER_BLOB {
        cbData: bytes.len().try_into()?,
        pbData: bytes.as_ptr() as *mut u8,
    };
    let mut target = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        if encrypt {
            CryptProtectData(
                &source,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut target,
            )
        } else {
            CryptUnprotectData(
                &source,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut target,
            )
        }
    };
    ensure!(ok != 0, "system key protection failed");
    let result =
        unsafe { std::slice::from_raw_parts(target.pbData, target.cbData as usize).to_vec() };
    unsafe {
        LocalFree(target.pbData as *mut _);
    }
    Ok(result)
}
#[cfg(windows)]
fn protect(_: &Path, b: &[u8]) -> Result<Vec<u8>> {
    crypt(b, true)
}
#[cfg(windows)]
fn unprotect(_: &Path, b: &[u8]) -> Result<Vec<u8>> {
    crypt(b, false)
}

#[cfg(target_os = "macos")]
fn protect(_: &Path, b: &[u8]) -> Result<Vec<u8>> {
    ensure!(b.len() == 32, "invalid device identity");
    let mut saved = b"private-file-v1\n".to_vec();
    saved.extend_from_slice(b);
    Ok(saved)
}
#[cfg(target_os = "macos")]
fn unprotect(root: &Path, b: &[u8]) -> Result<Vec<u8>> {
    use std::os::unix::fs::PermissionsExt;
    let secret = b
        .strip_prefix(b"private-file-v1\n")
        .context("invalid key storage version")?;
    ensure!(secret.len() == 32, "invalid device identity");
    fs::set_permissions(root.join("identity.key"), fs::Permissions::from_mode(0o600))?;
    Ok(secret.to_vec())
}
#[cfg(not(any(windows, target_os = "macos")))]
fn protect(_: &Path, _: &[u8]) -> Result<Vec<u8>> {
    anyhow::bail!("native Linux key storage is not implemented; use isolated test mode")
}
#[cfg(not(any(windows, target_os = "macos")))]
fn unprotect(_: &Path, _: &[u8]) -> Result<Vec<u8>> {
    anyhow::bail!("native Linux key storage is not implemented")
}

#[cfg(all(test, target_os = "macos"))]
mod mac_storage_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn private_file_identity_survives_restart_and_rotation() -> Result<()> {
        let temporary = tempfile::tempdir()?;
        let root = temporary.path().join("sync");
        let identity = Identity::load(&root, false)?;
        let signature = identity.sign(b"restart proof");
        let reloaded = Identity::load(&root, false)?;
        ensure!(
            identity.id() == reloaded.id(),
            "identity changed on restart"
        );
        verify(&reloaded.id(), b"restart proof", &signature)?;
        ensure!(fs::metadata(&root)?.permissions().mode() & 0o777 == 0o700);
        ensure!(
            fs::metadata(root.join("identity.key"))?
                .permissions()
                .mode()
                & 0o777
                == 0o600
        );
        let replaced = Identity::replace(&root, false)?;
        ensure!(identity.id() != replaced.id());
        ensure!(Identity::load(&root, false)?.id() == replaced.id());
        ensure!(Identity::load(&root, true).is_err());
        Ok(())
    }

    #[test]
    fn corrupt_private_identity_is_not_replaced() -> Result<()> {
        let root = tempfile::tempdir()?;
        let path = root.path().join("identity.key");
        atomic_write(&path, b"private-file-v1\ninvalid")?;
        ensure!(Identity::load(root.path(), false).is_err());
        ensure!(fs::read(path)? == b"private-file-v1\ninvalid");
        Ok(())
    }
}
