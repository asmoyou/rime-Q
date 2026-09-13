use crate::{
    identity::{self, Identity},
    model::*,
    network,
    store::{ApplyJob, Group, Member, Revocation, Store},
};
use anyhow::{bail, ensure, Context, Result};
use hmac::{Hmac, Mac};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;
use spake2::{Ed25519Group, Identity as PakeIdentity, Password, Spake2};
use std::{
    collections::BTreeMap,
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::{TcpListener, TcpStream},
    sync::oneshot,
};

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub const MAX_CONTROL: usize = 96 * 1024 * 1024;
type Shared = Arc<Mutex<State>>;
struct Invite {
    id: String,
    code: String,
    expires: Instant,
    attempts: u8,
}
struct Pending {
    name: String,
    accept: oneshot::Sender<bool>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    group: String,
    id: String,
    seq: u64,
    version: Vector,
    revision: String,
    signature: String,
}
impl Receipt {
    fn bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(&(
            "RimeQ.receipt.v1",
            &self.group,
            &self.id,
            self.seq,
            &self.version,
            &self.revision,
        ))?)
    }
}
struct Peer {
    address: SocketAddr,
    last_seen: u64,
    next_attempt: Instant,
    failures: u32,
}
struct State {
    store: Store,
    root: PathBuf,
    token: String,
    isolated: bool,
    port: u16,
    listening: bool,
    bind: std::net::IpAddr,
    invite: Option<Invite>,
    pending: BTreeMap<String, Pending>,
    peers: BTreeMap<String, Peer>,
    seen: BTreeMap<String, u64>,
    seen_saved: u64,
    discovered: BTreeMap<String, Value>,
    discover_until: Option<Instant>,
    discovery_tag: String,
    stop: bool,
    network_error: Option<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Hello {
    protocol: u32,
    id: String,
    nonce: String,
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "mode", deny_unknown_fields)]
enum Authenticate {
    Sync {
        id: String,
        group: String,
        members: Vec<Member>,
        signature: String,
    },
    Pair {
        id: String,
        name: String,
        invite: String,
        message: String,
    },
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Welcome {
    signature: String,
    revocations: Vec<Revocation>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    members: Vec<Member>,
    revocations: Vec<Revocation>,
    version: Vector,
    receipts: Vec<Receipt>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PairOffer {
    message: String,
    group: Group,
    proof: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PairProof {
    proof: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Enrollment {
    group: Group,
    grant: Member,
    members: Vec<Member>,
    revocations: Vec<Revocation>,
}

fn auth_bytes(
    binding: &[u8],
    hello: &Hello,
    id: &str,
    group: &str,
    members: &[Member],
) -> Result<Vec<u8>> {
    Ok(serde_json::to_vec(&(
        "RimeQ.TLS.identity.v1",
        identity::encode(binding),
        hello.protocol,
        &hello.id,
        &hello.nonce,
        id,
        group,
        members,
    ))?)
}
#[allow(clippy::too_many_arguments)] // Keep the complete authenticated transcript explicit.
fn confirmation(
    key: &[u8],
    role: &str,
    binding: &[u8],
    hello: &Hello,
    client: &str,
    group: &Group,
    a: &str,
    b: &str,
) -> Result<String> {
    let bytes = serde_json::to_vec(&(
        "RimeQ.pair.v1",
        role,
        identity::encode(binding),
        &hello.id,
        &hello.nonce,
        client,
        group,
        a,
        b,
    ))?;
    let mut mac = Hmac::<Sha256>::new_from_slice(key)?;
    mac.update(&bytes);
    Ok(identity::encode(&mac.finalize().into_bytes()))
}
fn same_secret(a: &str, b: &str) -> bool {
    // Equal length, constant-time MAC verification also avoids accepting prefix comparisons.
    let Ok(bytes) = identity::decode(b) else {
        return false;
    };
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(a.as_bytes()) else {
        return false;
    };
    mac.update(b"RimeQ.constant-time");
    let expected = mac.finalize().into_bytes();
    let Ok(mut other) = Hmac::<Sha256>::new_from_slice(b.as_bytes()) else {
        return false;
    };
    other.update(b"RimeQ.constant-time");
    bytes.len() == 32 && other.verify_slice(&expected).is_ok()
}
fn manifest(s: &State) -> Result<Manifest> {
    let receipts: BTreeMap<String, Receipt> = s.store.get("receipts")?.unwrap_or_default();
    Ok(Manifest {
        members: s.store.members()?,
        revocations: s.store.revocations()?,
        version: s.store.vector()?,
        receipts: receipts.into_values().collect(),
    })
}
fn accept_manifest(s: &mut State, value: &Manifest) -> Result<()> {
    ensure!(
        value.version.len() <= MAX_MEMBERS && value.receipts.len() <= MAX_MEMBERS,
        "manifest limits exceeded"
    );
    s.store.merge_view(&value.members, &value.revocations)?;
    let mut receipts: BTreeMap<String, Receipt> = s.store.get("receipts")?.unwrap_or_default();
    for r in &value.receipts {
        ensure!(
            r.group == s.store.group()?.id && r.version.len() <= MAX_MEMBERS,
            "invalid receipt"
        );
        if !s.store.authorized(&r.id)? {
            continue;
        }
        identity::verify(&r.id, &r.bytes()?, &r.signature)?;
        if receipts.get(&r.id).is_none_or(|old| r.seq > old.seq) {
            receipts.insert(r.id.clone(), r.clone());
        }
    }
    s.store.set("receipts", &receipts)
}
fn receipt(s: &State) -> Result<()> {
    let seq = s.store.get::<u64>("receipt_seq")?.unwrap_or(0) + 1;
    let mut r = Receipt {
        group: s.store.group()?.id,
        id: s.store.id(),
        seq,
        version: s.store.get("applied_vector")?.unwrap_or_default(),
        revision: s.store.get("applied_revision")?.unwrap_or_default(),
        signature: String::new(),
    };
    r.signature = s.store.identity.sign(&r.bytes()?);
    let mut receipts: BTreeMap<String, Receipt> = s.store.get("receipts")?.unwrap_or_default();
    receipts.insert(r.id.clone(), r);
    s.store.set("receipt_seq", &seq)?;
    s.store.set("receipts", &receipts)
}

async fn serve_peer(
    shared: Shared,
    tcp: TcpStream,
    acceptor: tokio_rustls::TlsAcceptor,
) -> Result<()> {
    let mut stream = tokio::time::timeout(Duration::from_secs(5), acceptor.accept(tcp)).await??;
    let binding =
        stream
            .get_ref()
            .1
            .export_keying_material([0u8; 32], b"EXPORTER-RimeQ-sync-v1", None)?;
    let hello = {
        let s = shared.lock().unwrap();
        ensure!(s.store.enabled(), "sync paused");
        Hello {
            protocol: PROTOCOL,
            id: s.store.id(),
            nonce: identity::random(),
        }
    };
    network::write(&mut stream, &hello).await?;
    let auth: Authenticate = network::read(&mut stream).await?;
    match auth {
        Authenticate::Sync {
            id,
            group,
            members,
            signature,
        } => {
            let (welcome, removed) = {
                let mut s = shared.lock().unwrap();
                ensure!(group == s.store.group()?.id, "wrong group");
                ensure!(members.len() <= MAX_MEMBERS, "membership limit");
                let bytes = auth_bytes(&binding, &hello, &id, &group, &members)?;
                identity::verify(&id, &bytes, &signature)?;
                let removed =
                    s.store.members()?.iter().any(|m| m.id == id) && !s.store.authorized(&id)?;
                if !removed {
                    s.store.admit_peer(&id, &members)?;
                }
                if let Some(p) = s.peers.get_mut(&id) {
                    p.last_seen = now();
                }
                s.seen.insert(id.clone(), now());
                if now().saturating_sub(s.seen_saved) >= 60 {
                    s.store.set("seen", &s.seen)?;
                    s.seen_saved = now();
                }
                (
                    Welcome {
                        signature: s.store.identity.sign(&bytes),
                        revocations: if removed {
                            s.store.revocations()?
                        } else {
                            Vec::new()
                        },
                    },
                    removed,
                )
            };
            network::write(&mut stream, &welcome).await?;
            if removed {
                return Ok(());
            }
            exchange(shared, &mut stream, false, &id).await
        }
        Authenticate::Pair {
            id,
            name,
            invite,
            message,
        } => {
            let (pake, out, group) = {
                let mut s = shared.lock().unwrap();
                crate::store::name(&name)?;
                ensure!(identity::decode(&id)?.len() == 32, "invalid identity");
                ensure!(s.store.authorized(&s.store.id())?, "inviter removed");
                let i = s.invite.as_mut().context("no open invitation")?;
                ensure!(
                    i.id == invite && i.expires > Instant::now() && i.attempts < 5,
                    "invitation expired or attempt limit reached"
                );
                i.attempts += 1;
                let server_id = format!("{}:{}", hello.id, invite);
                let (p, m) = Spake2::<Ed25519Group>::start_b(
                    &Password::new(i.code.as_bytes()),
                    &PakeIdentity::new(id.as_bytes()),
                    &PakeIdentity::new(server_id.as_bytes()),
                );
                (p, identity::encode(&m), s.store.group()?)
            };
            let key = pake
                .finish(&identity::decode(&message)?)
                .map_err(|_| anyhow::anyhow!("pairing rejected"))?;
            let proof = confirmation(
                &key, "server", &binding, &hello, &id, &group, &message, &out,
            )?;
            network::write(
                &mut stream,
                &PairOffer {
                    message: out.clone(),
                    group: group.clone(),
                    proof,
                },
            )
            .await?;
            let provided: PairProof = network::read(&mut stream).await?;
            ensure!(
                same_secret(
                    &confirmation(&key, "client", &binding, &hello, &id, &group, &message, &out)?,
                    &provided.proof
                ),
                "incorrect pairing code"
            );
            let receiver = {
                let mut s = shared.lock().unwrap();
                ensure!(s.pending.is_empty(), "another pairing is waiting");
                let (sender, receiver) = oneshot::channel();
                s.pending.insert(
                    id.clone(),
                    Pending {
                        name,
                        accept: sender,
                    },
                );
                s.invite = None;
                receiver
            };
            let accepted = tokio::time::timeout(Duration::from_secs(120), receiver).await;
            {
                shared.lock().unwrap().pending.remove(&id);
            }
            ensure!(
                accepted.ok().and_then(Result::ok).unwrap_or(false),
                "pairing was not approved"
            );
            let enrollment = {
                let s = shared.lock().unwrap();
                ensure!(
                    s.store.enabled() && s.store.authorized(&s.store.id())?,
                    "sync unavailable"
                );
                let grant = s
                    .store
                    .members()?
                    .into_iter()
                    .find(|m| m.id == id)
                    .context("membership not committed")?;
                Enrollment {
                    group: s.store.group()?,
                    grant,
                    members: s.store.members()?,
                    revocations: s.store.revocations()?,
                }
            };
            network::write(&mut stream, &enrollment).await
        }
    }
}
async fn exchange<S: AsyncRead + AsyncWrite + Unpin>(
    shared: Shared,
    stream: &mut S,
    client: bool,
    peer_id: &str,
) -> Result<()> {
    let own = {
        let s = shared.lock().unwrap();
        ensure!(s.store.enabled(), "sync paused");
        manifest(&s)?
    };
    let remote: Manifest = if client {
        network::write(stream, &own).await?;
        network::read(stream).await?
    } else {
        let r = network::read(stream).await?;
        network::write(stream, &own).await?;
        r
    };
    let outgoing = {
        let mut s = shared.lock().unwrap();
        accept_manifest(&mut s, &remote)?;
        ensure!(s.store.authorized(peer_id)?, "peer was removed");
        ensure!(
            !s.store.is_revoked(&s.store.id())?,
            "this device was removed"
        );
        s.store.missing(&remote.version, MAX_BATCH)?
    };
    let incoming: Vec<Operation> = if client {
        network::write(stream, &outgoing).await?;
        network::read(stream).await?
    } else {
        let r = network::read(stream).await?;
        network::write(stream, &outgoing).await?;
        r
    };
    {
        let s = shared.lock().unwrap();
        ensure!(s.store.enabled(), "sync paused");
        ensure!(s.store.authorized(peer_id)?, "peer was removed");
        s.store.receive(&incoming)?;
    }
    Ok(())
}
async fn sync_peer(shared: Shared, address: SocketAddr) -> Result<String> {
    let mut stream = network::connect(address).await?;
    let binding =
        stream
            .get_ref()
            .1
            .export_keying_material([0u8; 32], b"EXPORTER-RimeQ-sync-v1", None)?;
    let hello: Hello = network::read(&mut stream).await?;
    ensure!(hello.protocol == PROTOCOL, "incompatible peer");
    let (auth, bytes) = {
        let s = shared.lock().unwrap();
        ensure!(
            s.store.enabled() && s.store.authorized(&hello.id)?,
            "unknown or removed device"
        );
        let members = s.store.members()?;
        let group = s.store.group()?.id;
        let id = s.store.id();
        let bytes = auth_bytes(&binding, &hello, &id, &group, &members)?;
        (
            Authenticate::Sync {
                id,
                group,
                members,
                signature: s.store.identity.sign(&bytes),
            },
            bytes,
        )
    };
    network::write(&mut stream, &auth).await?;
    let welcome: Welcome = network::read(&mut stream).await?;
    identity::verify(&hello.id, &bytes, &welcome.signature)?;
    if !welcome.revocations.is_empty() {
        let mut s = shared.lock().unwrap();
        s.store.merge_revocations(&welcome.revocations)?;
        if !s.store.authorized(&s.store.id())? {
            s.store.set("enabled", &false)?;
            s.network_error =
                Some("这台电脑已被移出同步组。可退出后重新接受邀请，本机词库保留。".into());
        }
        bail!("this device was removed");
    }
    exchange(shared, &mut stream, true, &hello.id).await?;
    Ok(hello.id)
}
async fn join(
    shared: Shared,
    address: SocketAddr,
    invite: &str,
    code: &str,
    label: &str,
) -> Result<Value> {
    ensure!(
        code.len() == 6 && code.bytes().all(|b| b.is_ascii_digit()),
        "enter six digits"
    );
    crate::store::name(label)?;
    let id = {
        let s = shared.lock().unwrap();
        ensure!(
            s.store.get::<Group>("group")?.is_none(),
            "already in a group"
        );
        s.store.id()
    };
    let mut stream = network::connect(address).await?;
    let binding =
        stream
            .get_ref()
            .1
            .export_keying_material([0u8; 32], b"EXPORTER-RimeQ-sync-v1", None)?;
    let hello: Hello = network::read(&mut stream).await?;
    ensure!(hello.protocol == PROTOCOL, "incompatible peer");
    let server_id = format!("{}:{}", hello.id, invite);
    let (pake, message) = Spake2::<Ed25519Group>::start_a(
        &Password::new(code.as_bytes()),
        &PakeIdentity::new(id.as_bytes()),
        &PakeIdentity::new(server_id.as_bytes()),
    );
    let message = identity::encode(&message);
    network::write(
        &mut stream,
        &Authenticate::Pair {
            id: id.clone(),
            name: label.into(),
            invite: invite.into(),
            message: message.clone(),
        },
    )
    .await?;
    let offer: PairOffer = network::read(&mut stream).await?;
    let key = pake
        .finish(&identity::decode(&offer.message)?)
        .map_err(|_| anyhow::anyhow!("pairing rejected"))?;
    ensure!(
        same_secret(
            &confirmation(
                &key,
                "server",
                &binding,
                &hello,
                &id,
                &offer.group,
                &message,
                &offer.message
            )?,
            &offer.proof
        ),
        "incorrect pairing code or identity"
    );
    network::write(
        &mut stream,
        &PairProof {
            proof: confirmation(
                &key,
                "client",
                &binding,
                &hello,
                &id,
                &offer.group,
                &message,
                &offer.message,
            )?,
        },
    )
    .await?;
    let enrollment: Enrollment = tokio::time::timeout(
        Duration::from_secs(130),
        network::read_limit(&mut stream, MAX_FRAME),
    )
    .await??;
    ensure!(
        enrollment.group == offer.group && enrollment.grant.issuer == hello.id,
        "unexpected invitation authority"
    );
    {
        let mut s = shared.lock().unwrap();
        s.store.enroll(
            enrollment.group,
            enrollment.grant,
            &enrollment.members,
            &enrollment.revocations,
        )?;
        s.peers.insert(
            hello.id.clone(),
            Peer {
                address,
                last_seen: now(),
                next_attempt: Instant::now(),
                failures: 0,
            },
        );
        persist_peers(&s)?;
    }
    Ok(json!({"joined":true,"id":id}))
}
fn persist_peers(s: &State) -> Result<()> {
    let addresses: BTreeMap<_, _> = s
        .peers
        .iter()
        .map(|(id, p)| (id.clone(), p.address.to_string()))
        .collect();
    s.store.set("addresses", &addresses)
}

fn status(s: &State) -> Result<Value> {
    let version = s.store.vector()?;
    let revision = s.store.revision()?;
    let can_remove = s
        .store
        .get::<Group>("group")?
        .is_some_and(|g| g.founder == s.store.id());
    let receipts: BTreeMap<String, Receipt> = s.store.get("receipts")?.unwrap_or_default();
    let seen = &s.seen;
    let members:Vec<_>=s.store.members()?.iter().map(|m| {
        let p=s.peers.get(&m.id);let r=receipts.get(&m.id);let removed=!s.store.authorized(&m.id).unwrap_or(false);
        let last_seen=p.map(|p|p.last_seen).unwrap_or(0).max(seen.get(&m.id).copied().unwrap_or(0));
        let online=m.id==s.store.id() || now().saturating_sub(last_seen)<20;
        let applied=r.is_some_and(|r|r.revision==revision && covers(&r.version,&version));
        json!({"id":m.id,"name":m.name,"self":m.id==s.store.id(),"removed":removed,"online":online,"applied":applied,"last_seen":last_seen})
    }).collect();
    let pending: Vec<_> = s
        .pending
        .iter()
        .map(|(id, p)| json!({"id":id,"name":p.name}))
        .collect();
    Ok(
        json!({"protocol":PROTOCOL,"id":s.store.id(),"group":s.store.get::<Group>("group")?,"enabled":s.store.enabled(),"can_remove":can_remove,"members":members,"pending":pending,"discovered":s.discovered.values().collect::<Vec<_>>(),"port":s.port,"bind":s.bind.to_string(),"rows":s.store.rows()?.len(),"version":version,"revision":revision,"waiting_input":s.store.get::<ApplyJob>("apply_job")?.is_some(),"network_error":s.network_error}),
    )
}

async fn control(shared: Shared, value: Value) -> Result<Value> {
    let action = value
        .get("action")
        .and_then(Value::as_str)
        .context("missing action")?;
    let string = |name: &str| {
        value
            .get(name)
            .and_then(Value::as_str)
            .context("missing request field")
    };
    if action == "join" {
        let address = {
            let s = shared.lock().unwrap();
            network::address(string("address")?, s.isolated)?
        };
        return join(
            shared,
            address,
            string("invite")?,
            string("code")?,
            string("name")?,
        )
        .await;
    }
    if action == "invite" {
        // A configured fixed port does not prove that the listener is ready.
        // Wait before exposing an invitation, including on fast CI hosts.
        for _ in 0..40 {
            {
                let s = shared.lock().unwrap();
                ensure!(s.store.enabled() && !s.stop, "sync unavailable");
                if s.listening {
                    break;
                }
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        ensure!(
            shared.lock().unwrap().listening,
            "local network listener unavailable"
        );
    }
    let mut s = shared.lock().unwrap();
    ensure!(!s.stop, "sync service is restarting");
    match action {
        "status" => status(&s),
        "discover" => {
            s.discover_until = Some(Instant::now() + Duration::from_secs(120));
            status(&s)
        }
        "create" => {
            s.store.create_group(string("group")?, string("name")?)?;
            status(&s)
        }
        "invite" => {
            ensure!(
                s.store.enabled() && s.store.authorized(&s.store.id())?,
                "sync unavailable"
            );
            let i = Invite {
                id: identity::random(),
                code: format!("{:06}", rand::thread_rng().gen_range(0..1_000_000)),
                expires: Instant::now() + Duration::from_secs(300),
                attempts: 0,
            };
            let result = json!({"invite":i.id,"code":i.code,"expires_in":300,"port":s.port});
            s.invite = Some(i);
            Ok(result)
        }
        "cancel_invite" => {
            s.invite = None;
            for (_, p) in std::mem::take(&mut s.pending) {
                let _ = p.accept.send(false);
            }
            Ok(json!({"cancelled":true}))
        }
        "approve" => {
            let id = string("id")?;
            let p = s.pending.remove(id).context("pairing request expired")?;
            ensure!(
                s.store.enabled() && s.store.authorized(&s.store.id())?,
                "sync unavailable"
            );
            s.store.grant(id, &p.name)?;
            let _ = p.accept.send(true);
            Ok(json!({"approved":true}))
        }
        "reject" => {
            if let Some(p) = s.pending.remove(string("id")?) {
                let _ = p.accept.send(false);
            }
            Ok(json!({"rejected":true}))
        }
        "pause" => {
            s.store.set("enabled", &false)?;
            s.invite = None;
            Ok(json!({"enabled":false}))
        }
        "resume" => {
            ensure!(
                s.store.authorized(&s.store.id())?,
                "this device was removed"
            );
            s.store.set("enabled", &true)?;
            Ok(json!({"enabled":true}))
        }
        "remove" => {
            s.store.revoke(string("id")?)?;
            status(&s)
        }
        "add_peer" => {
            let address = network::address(string("address")?, s.isolated)?;
            let key = format!("address:{address}");
            s.peers.insert(
                key,
                Peer {
                    address,
                    last_seen: 0,
                    next_attempt: Instant::now(),
                    failures: 0,
                },
            );
            persist_peers(&s)?;
            Ok(json!({"added":true}))
        }
        "sync_now" => {
            for p in s.peers.values_mut() {
                p.next_attempt = Instant::now();
            }
            Ok(json!({"scheduled":true}))
        }
        "capture" => {
            let rows: Vec<Row> =
                serde_json::from_value(value.get("rows").context("missing rows")?.clone())?;
            s.store.capture(&rows)?;
            let job = s.store.prepare_apply()?;
            if job.is_none() {
                receipt(&s)?;
            }
            Ok(json!({"job":job}))
        }
        "prepare_apply" => {
            let job = s.store.prepare_apply()?;
            if job.is_none() {
                receipt(&s)?;
            }
            Ok(json!({"job":job}))
        }
        "pending_apply" => Ok(json!({"job":s.store.get::<ApplyJob>("apply_job")?})),
        "abort_unapplied" => {
            let job: ApplyJob = s
                .store
                .get("apply_job")?
                .context("no pending application")?;
            ensure!(job.id == string("id")?, "stale application");
            s.store.clear("apply_job")?;
            Ok(json!({"aborted":true}))
        }
        "acknowledge" => {
            let rows: Vec<Row> =
                serde_json::from_value(value.get("rows").context("missing rows")?.clone())?;
            s.store.acknowledge(string("id")?, &rows)?;
            receipt(&s)?;
            let _ = crate::backups::prune(&s.root);
            Ok(json!({"applied":true}))
        }
        "recover_local" => {
            let rows: Vec<Row> =
                serde_json::from_value(value.get("rows").context("missing rows")?.clone())?;
            s.store.recover_local(string("id")?, &rows)?;
            let job = s.store.prepare_apply()?;
            if job.is_none() {
                receipt(&s)?;
            }
            Ok(json!({"job":job}))
        }
        "shutdown" => {
            s.stop = true;
            Ok(json!({"stopping":true}))
        }
        "leave" => {
            let archives = s.root.join("archives");
            identity::private_directory(&archives)?;
            s.store
                .leave(&archives.join(format!("state-{}.sqlite", identity::random())))?;
            s.invite = None;
            s.pending.clear();
            s.stop = true;
            Ok(json!({"left":true}))
        }
        "fixture_change" => {
            ensure!(s.isolated, "fixture operations require isolated mode");
            let changes: Vec<Change> =
                serde_json::from_value(value.get("changes").context("missing changes")?.clone())?;
            s.store.change(changes)?;
            s.store.set("applied_vector", &s.store.vector()?)?;
            s.store.set("applied_revision", &s.store.revision()?)?;
            receipt(&s)?;
            Ok(json!({"version":s.store.vector()?}))
        }
        "fixture_rows" => {
            ensure!(s.isolated, "fixture operations require isolated mode");
            Ok(json!({"rows":s.store.rows()?}))
        }
        _ => bail!("unknown control action"),
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Descriptor {
    pub address: String,
    pub token: String,
    pub pid: u32,
}
#[derive(Serialize, Deserialize)]
struct ControlRequest {
    token: String,
    request: Value,
}
pub async fn client(root: &std::path::Path, request: Value) -> Result<Value> {
    let d: Descriptor = serde_json::from_slice(&std::fs::read(root.join("control.json"))?)?;
    let addr: SocketAddr = d.address.parse()?;
    ensure!(addr.ip().is_loopback(), "invalid local control endpoint");
    let mut stream =
        tokio::time::timeout(Duration::from_secs(3), TcpStream::connect(addr)).await??;
    network::write_limit(
        &mut stream,
        &ControlRequest {
            token: d.token,
            request,
        },
        MAX_CONTROL,
    )
    .await?;
    let value: Value = tokio::time::timeout(
        Duration::from_secs(140),
        network::read_limit(&mut stream, MAX_CONTROL),
    )
    .await??;
    if value.get("ok") == Some(&Value::Bool(true)) {
        Ok(value.get("result").cloned().unwrap_or(Value::Null))
    } else {
        bail!(
            "{}",
            value
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("sync request failed")
        )
    }
}

pub async fn run(
    root: PathBuf,
    bind: std::net::IpAddr,
    port: u16,
    isolated: bool,
    no_discovery: bool,
) -> Result<()> {
    identity::private_directory(&root)?;
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(root.join("service.lock"))?;
    fs2::FileExt::try_lock_exclusive(&lock).context("sync service is already running")?;
    let identity = Identity::load(&root, isolated)?;
    let mut store = Store::open(&root.join("state.sqlite"), identity)?;
    if store.get::<bool>("reset_identity")?.unwrap_or(false) {
        store.identity = Identity::replace(&root, isolated)?;
        store.clear("reset_identity")?;
    }
    let addresses: BTreeMap<String, String> = store.get("addresses")?.unwrap_or_default();
    let mut peers = BTreeMap::new();
    for (id, address) in addresses {
        if let Ok(address) = network::address(&address, isolated) {
            peers.insert(
                id,
                Peer {
                    address,
                    last_seen: 0,
                    next_attempt: Instant::now(),
                    failures: 0,
                },
            );
        }
    }
    let control_listener = TcpListener::bind("127.0.0.1:0").await?;
    let token = identity::random();
    let descriptor = Descriptor {
        address: control_listener.local_addr()?.to_string(),
        token: token.clone(),
        pid: std::process::id(),
    };
    identity::atomic_write(
        &root.join("control.json"),
        &serde_json::to_vec(&descriptor)?,
    )?;
    let seen = store.get("seen")?.unwrap_or_default();
    let shared = Arc::new(Mutex::new(State {
        store,
        root,
        token,
        isolated,
        port,
        listening: false,
        bind,
        invite: None,
        pending: BTreeMap::new(),
        peers,
        seen,
        seen_saved: now(),
        discovered: BTreeMap::new(),
        discover_until: None,
        discovery_tag: identity::random(),
        stop: false,
        network_error: None,
    }));
    let controls = shared.clone();
    let control_task = tokio::spawn(async move {
        let permits = Arc::new(tokio::sync::Semaphore::new(8));
        loop {
            let Ok((mut stream, source)) = control_listener.accept().await else {
                break;
            };
            if !source.ip().is_loopback() {
                continue;
            }
            let Ok(permit) = permits.clone().try_acquire_owned() else {
                continue;
            };
            let s = controls.clone();
            tokio::spawn(async move {
                let _permit = permit;
                let operation = async {
                    let request: ControlRequest =
                        network::read_limit(&mut stream, MAX_CONTROL).await?;
                    ensure!(
                        same_secret(&s.lock().unwrap().token, &request.token),
                        "local control authentication failed"
                    );
                    let response = match control(s, request.request).await {
                        Ok(v) => json!({"ok":true,"result":v}),
                        Err(e) => json!({"ok":false,"error":e.to_string()}),
                    };
                    network::write_limit(&mut stream, &response, MAX_CONTROL).await
                };
                let _: Result<_> = tokio::time::timeout(Duration::from_secs(145), operation)
                    .await
                    .map_err(Into::into)
                    .and_then(|x| x);
            });
        }
    });
    let acceptor = network::acceptor()?;
    let mut listener: Option<TcpListener> = None;
    let mut discovery: Option<Discovery> = None;
    let mut discovery_state = String::new();
    let mut discovery_retry = Instant::now();
    let peer_permits = Arc::new(tokio::sync::Semaphore::new(8));
    let mut tick = tokio::time::interval(Duration::from_millis(500));
    loop {
        tick.tick().await;
        let (enabled, browsing, stop) = {
            let s = shared.lock().unwrap();
            (
                s.store.enabled(),
                s.discover_until.is_some_and(|t| t > Instant::now()),
                s.stop,
            )
        };
        if stop {
            break;
        }
        if !enabled {
            listener = None;
            shared.lock().unwrap().listening = false;
        }
        if !enabled && !browsing {
            if let Some(d) = discovery.take() {
                let _ = d.shutdown();
            }
            discovery_state.clear();
            continue;
        }
        if !enabled {
            if !no_discovery && discovery.is_none() && Instant::now() >= discovery_retry {
                match discover(shared.clone(), 0) {
                    Ok(d) => discovery = Some(d),
                    Err(_) => discovery_retry = Instant::now() + Duration::from_secs(2),
                }
            }
            continue;
        }
        if listener.is_none() {
            match TcpListener::bind(SocketAddr::new(bind, port)).await {
                Ok(l) => {
                    let p = l.local_addr()?.port();
                    shared.lock().unwrap().port = p;
                    shared.lock().unwrap().listening = true;
                    listener = Some(l);
                }
                Err(_) => {
                    shared.lock().unwrap().network_error =
                        Some("无法监听本地网络，请检查网络与防火墙。".into());
                    continue;
                }
            }
        }
        if !no_discovery {
            let next = {
                let s = shared.lock().unwrap();
                format!(
                    "{}:{}",
                    s.port,
                    s.invite
                        .as_ref()
                        .filter(|i| i.expires > Instant::now())
                        .map(|i| i.id.as_str())
                        .unwrap_or("")
                )
            };
            if (discovery.is_none() || discovery_state != next) && Instant::now() >= discovery_retry
            {
                let p = shared.lock().unwrap().port;
                // mDNS notification errors must not stop authenticated transfers
                // or the local control service. A queued registration is safe
                // to repeat on the same daemon after a transient socket failure.
                let result = if let Some(d) = discovery.as_ref() {
                    discovery_info(&shared, p)
                        .and_then(|info| d.daemon.register(info).map_err(Into::into))
                } else {
                    discover(shared.clone(), p).map(|d| discovery = Some(d))
                };
                match result {
                    Ok(()) => {
                        discovery_state = next;
                        let mut s = shared.lock().unwrap();
                        if s.network_error.as_deref() == Some(DISCOVERY_ERROR) {
                            s.network_error = None;
                        }
                    }
                    Err(_) => {
                        discovery_retry = Instant::now() + Duration::from_secs(2);
                        shared.lock().unwrap().network_error = Some(DISCOVERY_ERROR.into());
                    }
                }
            }
        }
        if let Some(l) = &listener {
            for _ in 0..8 {
                let accepted = tokio::time::timeout(Duration::from_millis(1), l.accept()).await;
                let Ok(Ok((stream, source))) = accepted else {
                    break;
                };
                if !network::lan(source.ip(), isolated) {
                    continue;
                }
                let Ok(permit) = peer_permits.clone().try_acquire_owned() else {
                    continue;
                };
                let s = shared.clone();
                let a = acceptor.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    let _ =
                        tokio::time::timeout(Duration::from_secs(140), serve_peer(s, stream, a))
                            .await;
                });
            }
        }
        let targets = {
            let mut s = shared.lock().unwrap();
            let mut targets = Vec::new();
            let mut due: Vec<_> = s
                .peers
                .iter_mut()
                .filter(|(_, p)| p.next_attempt <= Instant::now())
                .collect();
            due.sort_by_key(|(_, p)| p.next_attempt);
            for (id, p) in due.into_iter().take(2) {
                targets.push((id.clone(), p.address));
                p.next_attempt = Instant::now() + Duration::from_secs(30);
            }
            targets
        };
        for (key, address) in targets {
            let s = shared.clone();
            tokio::spawn(async move {
                let result =
                    tokio::time::timeout(Duration::from_secs(12), sync_peer(s.clone(), address))
                        .await;
                let mut state = s.lock().unwrap();
                match result {
                    Ok(Ok(id)) => {
                        state.peers.remove(&key);
                        state.peers.retain(|_, p| p.address != address);
                        state.peers.insert(
                            id,
                            Peer {
                                address,
                                last_seen: now(),
                                next_attempt: Instant::now() + Duration::from_secs(2),
                                failures: 0,
                            },
                        );
                        let _ = persist_peers(&state);
                    }
                    _ => {
                        if let Some(p) = state.peers.get_mut(&key) {
                            p.failures = (p.failures + 1).min(6);
                            p.next_attempt =
                                Instant::now() + Duration::from_secs((1 << p.failures).min(60));
                        }
                    }
                }
            });
        }
    }
    if let Some(d) = discovery {
        let _ = d.shutdown();
    }
    control_task.abort();
    let root = shared.lock().unwrap().root.clone();
    let _ = std::fs::remove_file(root.join("control.json"));
    drop(lock);
    Ok(())
}

fn discovery_info(shared: &Shared, port: u16) -> Result<mdns_sd::ServiceInfo> {
    use mdns_sd::ServiceInfo;
    let service = "_rimeq-sync._tcp.local.";
    let tag = shared.lock().unwrap().discovery_tag.clone();
    let instance = format!("rq-{}", &tag[..12]);
    let invitation = {
        shared
            .lock()
            .unwrap()
            .invite
            .as_ref()
            .filter(|i| i.expires > Instant::now())
            .map(|i| i.id.clone())
            .unwrap_or_default()
    };
    let display_name = {
        let s = shared.lock().unwrap();
        if invitation.is_empty() {
            String::new()
        } else {
            s.store
                .members()?
                .into_iter()
                .find(|m| m.id == s.store.id())
                .map(|m| m.name)
                .unwrap_or_default()
        }
    };
    let props = [
        ("v", "1"),
        ("platform", std::env::consts::OS),
        ("invite", invitation.as_str()),
        ("name", display_name.as_str()),
    ];
    Ok(ServiceInfo::new(
        service,
        &instance,
        &format!("{instance}.local."),
        "",
        port,
        &props[..],
    )?
    .enable_addr_auto())
}

const DISCOVERY_ERROR: &str = "设备发现暂不可用，可使用连接地址。";

struct Discovery {
    daemon: mdns_sd::ServiceDaemon,
    stop: Arc<std::sync::atomic::AtomicBool>,
}
impl Discovery {
    fn shutdown(&self) -> Result<()> {
        self.stop.store(true, std::sync::atomic::Ordering::Release);
        self.daemon.shutdown()?;
        Ok(())
    }
}
impl Drop for Discovery {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}
fn discover(shared: Shared, port: u16) -> Result<Discovery> {
    use mdns_sd::{ServiceDaemon, ServiceEvent};
    let daemon = ServiceDaemon::new()?;
    // Own shutdown before any fallible setup, so partially initialized
    // discovery attempts cannot leave a daemon behind.
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let discovery = Discovery { daemon, stop };
    let service = "_rimeq-sync._tcp.local.";
    let info = discovery_info(&shared, port)?;
    let thread_stop = discovery.stop.clone();
    let own = info.get_fullname().to_string();
    if port != 0 {
        discovery.daemon.register(info)?;
    }
    let events = discovery.daemon.browse(service)?;
    std::thread::spawn(move || {
        while !thread_stop.load(std::sync::atomic::Ordering::Acquire) {
            let Ok(event) = events.recv_timeout(Duration::from_secs(1)) else {
                continue;
            };
            if let ServiceEvent::ServiceResolved(info) = event {
                if info.get_fullname() == own {
                    continue;
                }
                let mut s = shared.lock().unwrap();
                if (!s.store.enabled() && s.discover_until.is_none_or(|t| t <= Instant::now()))
                    || s.peers.len() >= MAX_MEMBERS * 2
                {
                    continue;
                }
                for ip in info.get_addresses_v4() {
                    let ip = std::net::IpAddr::V4(ip);
                    if !network::lan(ip, s.isolated) {
                        continue;
                    }
                    let address = SocketAddr::new(ip, info.get_port());
                    let key = format!("address:{address}");
                    if !s.peers.values().any(|p| p.address == address) {
                        s.peers.entry(key.clone()).or_insert(Peer {
                            address,
                            last_seen: 0,
                            next_attempt: Instant::now(),
                            failures: 0,
                        });
                    }
                    s.discovered.insert(key,json!({"address":address.to_string(),"invite":info.get_property_val_str("invite").unwrap_or(""),"name":info.get_property_val_str("name").filter(|n|!n.is_empty()).unwrap_or_else(||info.get_fullname().split('.').next().unwrap_or("Rime Q")).chars().filter(|c|!c.is_control()).take(128).collect::<String>()}));
                    break;
                }
            }
        }
    });
    Ok(discovery)
}
