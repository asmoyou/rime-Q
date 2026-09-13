use anyhow::Result;
use std::{
    fs,
    path::Path,
    time::{Duration, SystemTime},
};

/// Only automatic snapshots created by our native adapters are eligible.
/// Recent files are protected, including an adapter's in-flight application.
pub fn prune(root: &Path) -> Result<()> {
    let directory = root.join("backups");
    if !directory.is_dir() {
        return Ok(());
    }
    let mut files = Vec::new();
    for entry in fs::read_dir(&directory)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let metadata = fs::symlink_metadata(entry.path())?;
        if metadata.file_type().is_file() && name.starts_with("before-") && name.ends_with(".tsv") {
            files.push((metadata.modified()?, entry.path(), metadata.len()));
        }
    }
    files.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
    let now = SystemTime::now();
    let mut bytes = 0u64;
    for (index, (modified, path, size)) in files.iter().enumerate() {
        bytes = bytes.saturating_add(*size);
        let recent = now.duration_since(*modified).unwrap_or_default() < Duration::from_secs(60);
        if index > 0 && !recent && (index >= 20 || bytes > 64 * 1024 * 1024) {
            fs::remove_file(path)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retention_preserves_manual_recovery_and_recent_files() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("backups");
        fs::create_dir(&directory).unwrap();
        for i in 0..30 {
            let file = fs::File::create(directory.join(format!("before-{i:03}.tsv"))).unwrap();
            file.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(i))
                .unwrap();
        }
        for name in [
            "before-current.tsv",
            "recovery-local.tsv",
            "recovery-target.tsv",
            "manual.tsv",
        ] {
            fs::write(directory.join(name), b"synthetic backup").unwrap();
        }
        fs::create_dir(directory.join("before-directory.tsv")).unwrap();
        prune(root.path()).unwrap();
        for name in [
            "before-current.tsv",
            "recovery-local.tsv",
            "recovery-target.tsv",
            "manual.tsv",
            "before-directory.tsv",
        ] {
            assert!(directory.join(name).exists());
        }
        assert_eq!(fs::read_dir(directory).unwrap().count(), 24);
    }
}
