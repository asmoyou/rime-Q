use crate::{
    identity::{self, Identity},
    model::*,
};
use anyhow::{ensure, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Group {
    pub id: String,
    pub name: String,
    pub founder: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Member {
    pub group: String,
    pub id: String,
    pub name: String,
    pub issuer: String,
    pub nonce: String,
    pub signature: String,
}
impl Member {
    fn bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(&(
            "RimeQ.member.v1",
            &self.group,
            &self.id,
            &self.name,
            &self.issuer,
            &self.nonce,
        ))?)
    }
    pub fn hash(&self) -> Result<String> {
        Ok(identity::digest(&serde_json::to_vec(self)?))
    }
    fn verify(&self, group: &Group) -> Result<()> {
        ensure!(
            self.group == group.id
                && identity::decode(&self.id)?.len() == 32
                && identity::decode(&self.nonce)?.len() == 32,
            "invalid membership"
        );
        name(&self.name)?;
        identity::verify(&self.issuer, &self.bytes()?, &self.signature)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Revocation {
    pub group: String,
    pub target: String,
    pub issuer: String,
    pub nonce: String,
    pub cutoff: u64,
    pub retained_grants: BTreeSet<String>,
    pub signature: String,
}
impl Revocation {
    fn bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(&(
            "RimeQ.revoke.v1",
            &self.group,
            &self.target,
            &self.issuer,
            &self.nonce,
            self.cutoff,
            &self.retained_grants,
        ))?)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ApplyJob {
    #[serde(default = "legacy_protocol")]
    pub protocol: u32,
    pub id: String,
    pub before: Vec<Row>,
    pub after: Vec<Row>,
    pub version: Vector,
    pub revision: String,
}
fn legacy_protocol() -> u32 { 1 }

pub struct Store {
    pub identity: Identity,
    db: Connection,
    row_count_cache: std::cell::Cell<Option<(u64, usize)>>,
    revision_cache: std::cell::RefCell<Option<(u64, String)>>,
}
pub fn name(value: &str) -> Result<()> {
    ensure!(
        !value.trim().is_empty() && value.len() <= 128 && !value.chars().any(char::is_control),
        "invalid name"
    );
    Ok(())
}

impl Store {
    /// The caller holds the service lock before loading persistent sync state.
    pub fn load(root: &Path, isolated: bool) -> Result<Self> {
        #[cfg(target_os = "macos")]
        let obsolete_identity = !isolated
            && std::fs::read(root.join("identity.key")).ok().as_deref() == Some(b"keychain-v1")
            && !root.join("isolated-test-only").exists();
        #[cfg(not(target_os = "macos"))]
        let obsolete_identity = false;
        let identity = if obsolete_identity {
            Identity::generate()
        } else {
            Identity::load(root, isolated)?
        };
        let mut store = Self::open(&root.join("state.sqlite"), identity)?;
        if obsolete_identity {
            // Unreleased Keychain identities are abandoned without accessing Keychain.
            // Archive only sync state; the native personal dictionary is independent.
            let archives = root.join("archives");
            identity::private_directory(&archives)?;
            store.leave(&archives.join(format!("state-{}.sqlite", identity::random())))?;
        }
        if store.get::<bool>("reset_identity")?.unwrap_or(false) {
            store.identity = Identity::replace(root, isolated)?;
            store.clear("reset_identity")?;
        }
        Ok(store)
    }

    pub fn open(path: &Path, identity: Identity) -> Result<Self> {
        Self::init(Connection::open(path)?, identity)
    }
    pub fn memory(identity: Identity) -> Result<Self> {
        Self::init(Connection::open_in_memory()?, identity)
    }
    fn init(db: Connection, identity: Identity) -> Result<Self> {
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        ensure!(
            (0..=2).contains(&version),
            "unsupported sync storage version"
        );
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS members(id TEXT PRIMARY KEY, body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS revocations(nonce TEXT PRIMARY KEY, body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS ops(origin TEXT NOT NULL, seq INTEGER NOT NULL, body TEXT NOT NULL, processed INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(origin,seq));
            CREATE INDEX IF NOT EXISTS ops_pending ON ops(processed);
            CREATE TABLE IF NOT EXISTS vector(origin TEXT PRIMARY KEY, seq INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS heads(key TEXT NOT NULL, origin TEXT NOT NULL, seq INTEGER NOT NULL, context TEXT NOT NULL, weight INTEGER, PRIMARY KEY(key,origin,seq));
            CREATE TABLE IF NOT EXISTS barriers(key TEXT NOT NULL, origin TEXT NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY(key,origin));
            CREATE TABLE IF NOT EXISTS baseline(key TEXT PRIMARY KEY, body TEXT NOT NULL);
            PRAGMA user_version=2;")?;
        Ok(Self { identity, db, row_count_cache: std::cell::Cell::new(None), revision_cache: std::cell::RefCell::new(None) })
    }
    pub fn id(&self) -> String {
        self.identity.id()
    }
    pub fn get<T: DeserializeOwned>(&self, key: &str) -> Result<Option<T>> {
        let value: Option<String> = self
            .db
            .query_row("SELECT value FROM meta WHERE key=?", [key], |r| r.get(0))
            .optional()?;
        value.map(|s| Ok(serde_json::from_str(&s)?)).transpose()
    }
    pub fn set<T: Serialize>(&self, key: &str, value: &T) -> Result<()> {
        self.db.execute(
            "INSERT INTO meta VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value!=excluded.value",
            params![key, serde_json::to_string(value)?],
        )?;
        Ok(())
    }
    pub fn clear(&self, key: &str) -> Result<()> {
        self.db.execute("DELETE FROM meta WHERE key=?", [key])?;
        Ok(())
    }
    pub fn group(&self) -> Result<Group> {
        self.get("group")?.context("not in a sync group")
    }
    pub fn enabled(&self) -> bool {
        self.get::<bool>("enabled").ok().flatten().unwrap_or(false)
    }
    pub fn create_group(&self, label: &str, device: &str) -> Result<Group> {
        name(label)?;
        name(device)?;
        ensure!(self.get::<Group>("group")?.is_none(), "already in a group");
        let group = Group {
            id: identity::random(),
            name: label.into(),
            founder: self.id(),
        };
        self.transaction(|| {
            self.set("group", &group)?;
            self.grant(&self.id(), device)?;
            self.set("enabled", &true)
        })?;
        Ok(group)
    }
    pub fn grant(&self, id: &str, label: &str) -> Result<Member> {
        name(label)?;
        ensure!(identity::decode(id)?.len() == 32, "invalid device identity");
        ensure!(
            self.members()?.len() < MAX_MEMBERS,
            "member capacity reached"
        );
        ensure!(!self.is_revoked(&self.id())?, "this device was removed");
        let mut grant = Member {
            group: self.group()?.id,
            id: id.into(),
            name: label.into(),
            issuer: self.id(),
            nonce: identity::random(),
            signature: String::new(),
        };
        grant.signature = self.identity.sign(&grant.bytes()?);
        self.db.execute(
            "INSERT INTO members VALUES(?,?)",
            params![id, serde_json::to_string(&grant)?],
        )?;
        Ok(grant)
    }
    pub fn join_group(&self, group: Group, grant: Member) -> Result<()> {
        ensure!(self.get::<Group>("group")?.is_none(), "already in a group");
        ensure!(grant.id == self.id(), "membership is for another device");
        grant.verify(&group)?;
        // Caller must authenticate the inviter through the one-use pairing exchange.
        self.transaction(|| {
            self.set("group", &group)?;
            self.db.execute(
                "INSERT INTO members VALUES(?,?)",
                params![grant.id, serde_json::to_string(&grant)?],
            )?;
            self.set("enabled", &true)
        })
    }
    pub fn members(&self) -> Result<Vec<Member>> {
        self.json_rows("SELECT body FROM members ORDER BY id")
    }
    pub fn revocations(&self) -> Result<Vec<Revocation>> {
        self.json_rows("SELECT body FROM revocations ORDER BY nonce")
    }
    pub fn is_revoked(&self, id: &str) -> Result<bool> {
        Ok(self.revocations()?.iter().any(|r| r.target == id))
    }
    pub fn authorized(&self, id: &str) -> Result<bool> {
        if self.is_revoked(id)? {
            return Ok(false);
        }
        self.historical_chain_valid(id)
    }
    fn historical_chain_valid(&self, id: &str) -> Result<bool> {
        let members = self.members()?;
        let revocations = self.revocations()?;
        let map: BTreeMap<_, _> = members.iter().map(|m| (m.id.as_str(), m)).collect();
        fn valid(
            id: &str,
            map: &BTreeMap<&str, &Member>,
            revocations: &[Revocation],
            founder: &str,
            visiting: &mut BTreeSet<String>,
        ) -> Result<bool> {
            let Some(m) = map.get(id) else {
                return Ok(false);
            };
            if !visiting.insert(id.into()) {
                return Ok(false);
            }
            if m.id == founder && m.issuer == founder {
                return Ok(true);
            }
            for r in revocations.iter().filter(|r| r.target == m.issuer) {
                if !r.retained_grants.contains(&m.hash()?) {
                    return Ok(false);
                }
            }
            valid(&m.issuer, map, revocations, founder, visiting)
        }
        valid(
            id,
            &map,
            &revocations,
            &self.group()?.founder,
            &mut BTreeSet::new(),
        )
    }
    pub fn merge_members(&self, values: &[Member]) -> Result<()> {
        ensure!(values.len() <= MAX_MEMBERS, "member capacity exceeded");
        let group = self.group()?;
        for m in values {
            m.verify(&group)?;
        }
        self.transaction(|| {
            let mut todo = values.to_vec();
            while !todo.is_empty() {
                let before = todo.len();
                let known: BTreeSet<_> = self.members()?.iter().map(|m| m.id.clone()).collect();
                let mut later = Vec::new();
                for m in todo {
                    if !(known.contains(&m.issuer)
                        || m.id == group.founder && m.issuer == group.founder)
                    {
                        later.push(m);
                        continue;
                    }
                    let prior: Option<String> = self
                        .db
                        .query_row("SELECT body FROM members WHERE id=?", [&m.id], |r| r.get(0))
                        .optional()?;
                    if let Some(body) = prior {
                        ensure!(
                            serde_json::from_str::<Member>(&body)? == m,
                            "conflicting membership identity"
                        );
                    } else {
                        ensure!(
                            (m.id == group.founder && m.issuer == group.founder)
                                || self.historical_chain_valid(&m.issuer)?,
                            "untrusted membership issuer"
                        );
                        for r in self.revocations()?.iter().filter(|r| r.target == m.issuer) {
                            ensure!(
                                r.retained_grants.contains(&m.hash()?),
                                "grant was not retained when issuer was removed"
                            );
                        }
                        self.db.execute(
                            "INSERT INTO members VALUES(?,?)",
                            params![m.id, serde_json::to_string(&m)?],
                        )?;
                    }
                }
                ensure!(later.len() < before, "untrusted membership chain");
                todo = later;
            }
            ensure!(
                self.members()?.len() <= MAX_MEMBERS,
                "member capacity exceeded"
            );
            Ok(())
        })
    }
    pub fn revoke(&self, target: &str) -> Result<Revocation> {
        ensure!(
            self.id() == self.group()?.founder,
            "only the group creator can remove devices"
        );
        ensure!(target != self.id(), "use leave group to remove this device");
        ensure!(
            self.authorized(&self.id())? && self.authorized(target)?,
            "invalid member removal"
        );
        let mut r = Revocation {
            group: self.group()?.id,
            target: target.into(),
            issuer: self.id(),
            nonce: identity::random(),
            cutoff: self.vector()?.get(target).copied().unwrap_or(0),
            retained_grants: self
                .members()?
                .iter()
                .map(Member::hash)
                .collect::<Result<_>>()?,
            signature: String::new(),
        };
        r.signature = self.identity.sign(&r.bytes()?);
        self.merge_revocations(std::slice::from_ref(&r))?;
        Ok(r)
    }
    pub fn admit_peer(&self, id: &str, members: &[Member]) -> Result<()> {
        self.transaction(|| {
            self.merge_members(members)?;
            ensure!(self.authorized(id)?, "device is not a group member");
            Ok(())
        })
    }
    pub fn merge_view(&self, members: &[Member], revocations: &[Revocation]) -> Result<()> {
        self.transaction(|| {
            self.merge_members(members)?;
            self.merge_revocations(revocations)
        })
    }
    pub fn enroll(
        &self,
        group: Group,
        grant: Member,
        members: &[Member],
        revocations: &[Revocation],
    ) -> Result<()> {
        self.transaction(|| {
            self.join_group(group, grant)?;
            self.merge_view(members, revocations)?;
            ensure!(
                self.authorized(&self.id())?,
                "new membership is not authorized"
            );
            Ok(())
        })
    }
    pub fn merge_revocations(&self, values: &[Revocation]) -> Result<()> {
        ensure!(values.len() <= MAX_MEMBERS * 2, "too many revocations");
        let group = self.group()?;
        // A single immutable management authority signs removals. Dictionary
        // traffic and invitations remain decentralized and work while it is off.
        for r in values {
            ensure!(
                r.group == group.id
                    && r.target != r.issuer
                    && r.issuer == group.founder
                    && identity::decode(&r.nonce)?.len() == 32
                    && r.cutoff < i64::MAX as u64
                    && r.retained_grants.len() <= MAX_MEMBERS,
                "invalid revocation"
            );
            identity::verify(&r.issuer, &r.bytes()?, &r.signature)?;
            let prior: Option<String> = self
                .db
                .query_row(
                    "SELECT body FROM revocations WHERE nonce=?",
                    [&r.nonce],
                    |v| v.get(0),
                )
                .optional()?;
            ensure!(
                prior.is_none_or(|p| p == serde_json::to_string(r).unwrap_or_default()),
                "revocation nonce reused"
            );
        }
        self.transaction(|| {
            let mut changed = false;
            for r in values {
                changed |= self.db.execute(
                    "INSERT OR IGNORE INTO revocations VALUES(?,?)",
                    params![r.nonce, serde_json::to_string(r)?],
                )? > 0;
            }
            if changed {
                self.rebuild()?;
            }
            Ok(())
        })
    }
    pub fn vector(&self) -> Result<Vector> {
        let mut q = self
            .db
            .prepare("SELECT origin,seq FROM vector ORDER BY origin")?;
        let result = q
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(result)
    }
    pub fn revision(&self) -> Result<String> {
        let generation = self.db.total_changes();
        if let Some((prior, value)) = self.revision_cache.borrow().as_ref() {
            if *prior == generation { return Ok(value.clone()); }
        }
        let value = identity::digest(&serde_json::to_vec(&(
            self.get::<Group>("group")?, self.members()?, self.revocations()?, self.vector()?,
        ))?);
        *self.revision_cache.borrow_mut() = Some((generation, value.clone()));
        Ok(value)
    }
    pub fn row_count(&self) -> Result<usize> {
        let generation = self.db.total_changes();
        if let Some((prior, count)) = self.row_count_cache.get() {
            if prior == generation { return Ok(count); }
        }
        let count = self.db.query_row(
            "SELECT COUNT(*) FROM (SELECT key FROM heads GROUP BY key HAVING SUM(weight IS NULL)=0)",
            [], |r| r.get(0))?;
        self.row_count_cache.set(Some((generation, count)));
        Ok(count)
    }
    pub fn has_pending_application(&self) -> Result<bool> {
        Ok(self.db.query_row("SELECT EXISTS(SELECT 1 FROM meta WHERE key='apply_job')", [], |r| r.get(0))?)
    }
    fn cutoffs(&self) -> Result<Vector> {
        let mut result = Vector::new();
        for r in self.revocations()? {
            let v = result.entry(r.target).or_insert(r.cutoff);
            *v = (*v).min(r.cutoff);
        }
        for m in self.members()? {
            if !self.historical_chain_valid(&m.id)? {
                result.insert(m.id, 0);
            }
        }
        Ok(result)
    }
    fn effective(&self, mut v: Vector) -> Result<Vector> {
        for (id, cutoff) in self.cutoffs()? {
            if let Some(x) = v.get_mut(&id) {
                *x = (*x).min(cutoff);
            }
        }
        Ok(v)
    }
    pub fn change(&self, changes: Vec<Change>) -> Result<Vec<Operation>> {
        self.change_observed(changes, self.vector()?)
    }
    fn change_observed(
        &self,
        changes: Vec<Change>,
        mut observed: Vector,
    ) -> Result<Vec<Operation>> {
        ensure!(
            !changes.is_empty() && changes.len() <= MAX_ROWS,
            "invalid change count"
        );
        let mut result = Vec::new();
        self.transaction(|| {
            for chunk in changes.chunks(MAX_BATCH) {
                let seq = self.vector()?.get(&self.id()).copied().unwrap_or(0) + 1;
                if seq > 1 {
                    observed.insert(self.id(), seq - 1);
                }
                let mut op = Operation {
                    protocol: PROTOCOL,
                    group: self.group()?.id,
                    origin: self.id(),
                    seq,
                    context: observed.clone(),
                    changes: chunk.to_vec(),
                    signature: String::new(),
                };
                op.signature = self.identity.sign(&op.signing_bytes()?);
                self.receive_inner(std::slice::from_ref(&op))?;
                result.push(op);
            }
            Ok(())
        })?;
        Ok(result)
    }
    pub fn receive(&self, ops: &[Operation]) -> Result<()> {
        if ops.is_empty() { return Ok(()); }
        self.transaction(|| self.receive_inner(ops))
    }
    fn receive_inner(&self, ops: &[Operation]) -> Result<()> {
        ensure!(ops.len() <= MAX_BATCH, "batch limit exceeded");
        let group = self.group()?;
        let cutoffs = self.cutoffs()?;
        for op in ops {
            op.validate()?;
            ensure!(op.group == group.id, "wrong group");
            let known = self.members()?.iter().any(|m| m.id == op.origin);
            ensure!(
                known
                    && (self.authorized(&op.origin)?
                        || cutoffs.get(&op.origin).is_some_and(|v| op.seq <= *v)),
                "operation origin unauthorized"
            );
            ensure!(
                op.context.keys().all(|id| self
                    .members()
                    .map(|ms| ms.iter().any(|m| &m.id == id))
                    .unwrap_or(false)),
                "unknown causal origin"
            );
            identity::verify(&op.origin, &op.signing_bytes()?, &op.signature)?;
            let body = serde_json::to_string(op)?;
            let prior: Option<String> = self
                .db
                .query_row(
                    "SELECT body FROM ops WHERE origin=? AND seq=?",
                    params![op.origin, op.seq],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(prior) = prior {
                ensure!(prior == body, "origin sequence reused with different data");
            } else {
                self.db.execute(
                    "INSERT INTO ops(origin,seq,body) VALUES(?,?,?)",
                    params![op.origin, op.seq, body],
                )?;
            }
        }
        self.drain()?;
        let count: usize = self
            .db
            .query_row("SELECT COUNT(DISTINCT key) FROM heads", [], |r| r.get(0))?;
        ensure!(count <= MAX_ROWS, "dictionary capacity exceeded");
        let pending: usize =
            self.db
                .query_row("SELECT COUNT(*) FROM ops WHERE processed=0", [], |r| {
                    r.get(0)
                })?;
        ensure!(pending <= 10_000, "pending causal data capacity exceeded");
        Ok(())
    }
    fn drain(&self) -> Result<()> {
        loop {
            let pending: Vec<Operation> =
                self.json_rows("SELECT body FROM ops WHERE processed=0 ORDER BY rowid")?;
            let mut progress = false;
            let cutoffs = self.cutoffs()?;
            for op in pending {
                if cutoffs.get(&op.origin).is_some_and(|v| op.seq > *v) {
                    continue;
                }
                let vector = self.vector()?;
                if vector.get(&op.origin).copied().unwrap_or(0) + 1 != op.seq
                    || !covers(&vector, &self.effective(op.context.clone())?)
                {
                    continue;
                }
                for c in &op.changes {
                    let key = c.key.id();
                    if c.weight.is_none() {
                        self.db.execute("INSERT INTO barriers VALUES(?,?,?) ON CONFLICT(key,origin) DO UPDATE SET seq=MAX(seq,excluded.seq)",params![key,op.origin,op.seq])?;
                    }
                    let mut q = self
                        .db
                        .prepare("SELECT origin,seq,context FROM heads WHERE key=?")?;
                    let heads: Vec<(String, u64, String)> = q
                        .query_map([&key], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                        .collect::<rusqlite::Result<_>>()?;
                    drop(q);
                    let mut obsolete = false;
                    if c.weight.is_some() {
                        let mut b = self
                            .db
                            .prepare("SELECT origin,seq FROM barriers WHERE key=?")?;
                        let barriers: Vec<(String, u64)> = b
                            .query_map([&key], |r| Ok((r.get(0)?, r.get(1)?)))?
                            .collect::<rusqlite::Result<_>>()?;
                        obsolete = barriers
                            .iter()
                            .any(|(id, seq)| op.context.get(id).copied().unwrap_or(0) < *seq);
                    }
                    for (origin, seq, context) in heads {
                        let other: Vector = serde_json::from_str(&context)?;
                        if other.get(&op.origin).copied().unwrap_or(0) >= op.seq {
                            obsolete = true;
                        }
                        if op.context.get(&origin).copied().unwrap_or(0) >= seq
                            || c.weight.is_none()
                                && other.get(&op.origin).copied().unwrap_or(0) < op.seq
                        {
                            self.db.execute(
                                "DELETE FROM heads WHERE key=? AND origin=? AND seq=?",
                                params![key, origin, seq],
                            )?;
                        }
                    }
                    if !obsolete {
                        self.db.execute(
                            "INSERT INTO heads VALUES(?,?,?,?,?)",
                            params![
                                key,
                                op.origin,
                                op.seq,
                                serde_json::to_string(&op.context)?,
                                c.weight
                            ],
                        )?;
                    }
                }
                self.db.execute(
                    "INSERT OR REPLACE INTO vector VALUES(?,?)",
                    params![op.origin, op.seq],
                )?;
                self.db.execute(
                    "UPDATE ops SET processed=1 WHERE origin=? AND seq=?",
                    params![op.origin, op.seq],
                )?;
                progress = true;
            }
            if !progress {
                break;
            }
        }
        Ok(())
    }
    fn rebuild(&self) -> Result<()> {
        self.db.execute_batch("DELETE FROM heads; DELETE FROM barriers; DELETE FROM vector; UPDATE ops SET processed=0;")?;
        self.drain()
    }
    pub fn missing(&self, known: &Vector, limit: usize) -> Result<Vec<Operation>> {
        ensure!(
            known.len() <= MAX_MEMBERS && limit <= MAX_BATCH,
            "invalid version request"
        );
        // SQLite filters acknowledged history before deserialization. Walk in
        // causal insertion order and bound the entire serialized network frame.
        if covers(known, &self.vector()?) { return Ok(Vec::new()); }
        let mut query = self.db.prepare("SELECT body FROM ops WHERE processed=1 AND seq > COALESCE((SELECT value FROM json_each(?1) WHERE key=origin),0) ORDER BY rowid LIMIT ?2")?;
        let mut cursor = query.query(params![serde_json::to_string(known)?, limit])?;
        let mut result = Vec::new();
        let mut size = 2;
        while let Some(row) = cursor.next()? {
            let body: String = row.get(0)?;
            if size + body.len() + 1 > MAX_FRAME {
                break;
            }
            size += body.len() + 1;
            result.push(serde_json::from_str(&body)?);
        }
        Ok(result)
    }
    pub fn rows(&self) -> Result<Vec<Row>> {
        let mut q = self.db.prepare(
            "SELECT key,MAX(weight),SUM(weight IS NULL) FROM heads GROUP BY key ORDER BY key",
        )?;
        let values: Vec<(String, Option<u32>, usize)> = q
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?;
        let mut rows = Vec::new();
        for (key, weight, deletions) in values {
            if deletions > 0 {
                continue;
            }
            let parts: Vec<_> = key.split('\t').collect();
            ensure!(parts.len() == 3, "damaged stored key");
            rows.push(Row {
                key: Key {
                    namespace: parts[0].into(),
                    text: parts[1].into(),
                    code: parts[2].into(),
                },
                weight: weight.context("missing weight")?,
            });
        }
        Ok(rows)
    }
    pub fn baseline(&self) -> Result<Vec<Row>> {
        self.json_rows("SELECT body FROM baseline ORDER BY key")
    }
    fn set_baseline(&self, rows: &[Row]) -> Result<()> {
        self.db.execute("DELETE FROM baseline", [])?;
        for row in rows {
            self.db.execute(
                "INSERT INTO baseline VALUES(?,?)",
                params![row.key.id(), serde_json::to_string(row)?],
            )?;
        }
        Ok(())
    }
    pub fn capture(&self, rows: &[Row]) -> Result<()> {
        ensure!(
            self.get::<ApplyJob>("apply_job")?.is_none(),
            "recover pending engine application first"
        );
        ensure!(rows.len() <= MAX_ROWS, "dictionary capacity exceeded");
        let mut current = BTreeMap::new();
        for r in rows {
            r.validate()?;
            ensure!(
                current.insert(r.key.clone(), r.weight).is_none(),
                "duplicate dictionary key"
            );
        }
        let previous: BTreeMap<_, _> = self
            .baseline()?
            .into_iter()
            .map(|r| (r.key, r.weight))
            .collect();
        let mut changes = Vec::new();
        for (key, weight) in &current {
            if previous.get(key) != Some(weight) {
                changes.push(Change {
                    key: key.clone(),
                    weight: Some(*weight),
                });
            }
        }
        for key in previous.keys() {
            if !current.contains_key(key) {
                changes.push(Change {
                    key: key.clone(),
                    weight: None,
                });
            }
        }
        self.transaction(|| {
            if !changes.is_empty() {
                // The engine has only observed acknowledged applications.
                // Receiving a deletion in the helper does not make older local
                // learning a deliberate re-add after that deletion.
                self.change_observed(changes.clone(), self.get("applied_vector")?.unwrap_or_default())?;
                for change in &changes {
                    if let Some(weight) = change.weight {
                        let row = Row { key: change.key.clone(), weight };
                        self.db.execute("INSERT INTO baseline VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET body=excluded.body",
                            params![row.key.id(), serde_json::to_string(&row)?])?;
                    } else {
                        self.db.execute("DELETE FROM baseline WHERE key=?", [change.key.id()])?;
                    }
                }
            }
            self.set("captured", &true)
        })
    }
    pub fn prepare_apply(&self) -> Result<Option<ApplyJob>> {
        if let Some(job) = self.get("apply_job")? {
            return Ok(Some(job));
        }
        ensure!(
            self.get::<bool>("captured")?.unwrap_or(false),
            "local dictionary has not been captured"
        );
        let before = self.baseline()?;
        let after = self.rows()?;
        if before == after {
            self.set("applied_vector", &self.vector()?)?;
            self.set("applied_revision", &self.revision()?)?;
            return Ok(None);
        }
        let job = ApplyJob {
            protocol: PROTOCOL,
            id: identity::random(),
            before,
            after,
            version: self.vector()?,
            revision: self.revision()?,
        };
        self.set("apply_job", &job)?;
        Ok(Some(job))
    }
    // v1 Windows could keep non-syllable rows outside its pending snapshot.
    // Reconcile only an exact before/after match; never guess after partial writes.
    pub fn upgrade_pending(&self, rows: &[Row]) -> Result<bool> {
        let Some(job) = self.get::<ApplyJob>("apply_job")? else { return Ok(false) };
        if job.protocol != 1 { return Ok(false); }
        ensure!(rows.len() <= MAX_ROWS, "dictionary capacity exceeded");
        let mut unique = BTreeSet::new();
        for row in rows { row.validate()?; ensure!(unique.insert(&row.key), "duplicate dictionary key"); }
        let legacy: Vec<Row> = rows.iter().filter(|r|r.key.validate_legacy().is_ok()).cloned().collect();
        let map = |values: &[Row]| values.iter().map(|r|(r.key.clone(),r.weight)).collect::<BTreeMap<_,_>>();
        let actual=map(&legacy);
        ensure!(actual==map(&job.before)||actual==map(&job.after), "recover pending engine application first");
        self.transaction(|| {
            if actual==map(&job.after) { self.acknowledge(&job.id,&legacy)?; }
            else { self.clear("apply_job")?; }
            self.capture(rows)?;
            self.prepare_apply()?;
            Ok(true)
        })
    }
    pub fn acknowledge(&self, id: &str, rows: &[Row]) -> Result<()> {
        let job: ApplyJob = self
            .get("apply_job")?
            .context("no pending engine application")?;
        ensure!(job.id == id, "stale application acknowledgement");
        let actual: BTreeMap<_, _> = rows.iter().map(|r| (&r.key, r.weight)).collect();
        let expected: BTreeMap<_, _> = job.after.iter().map(|r| (&r.key, r.weight)).collect();
        ensure!(
            actual == expected && rows.len() == expected.len(),
            "engine readback differs from expected dictionary"
        );
        self.transaction(|| {
            self.set_baseline(rows)?;
            self.set("applied_vector", &job.version)?;
            self.set("applied_revision", &job.revision)?;
            self.clear("apply_job")
        })
    }
    pub fn recover_local(&self, id: &str, rows: &[Row]) -> Result<()> {
        let job: ApplyJob = self
            .get("apply_job")?
            .context("no pending engine application")?;
        ensure!(job.id == id, "stale recovery request");
        // Explicit user decision: the current engine snapshot supersedes the
        // interrupted target. Native clients retain both snapshots first.
        self.transaction(|| {
            self.set_baseline(&self.rows()?)?;
            self.set("applied_vector", &self.vector()?)?;
            self.clear("apply_job")?;
            self.capture(rows)
        })
    }
    pub fn leave(&self, archive: &Path) -> Result<()> {
        ensure!(!archive.exists(), "archive already exists");
        self.db
            .execute("VACUUM INTO ?", [archive.to_string_lossy().as_ref()])?;
        self.transaction(|| {
            self.db.execute_batch("DELETE FROM meta; DELETE FROM members; DELETE FROM revocations; DELETE FROM ops; DELETE FROM vector; DELETE FROM heads; DELETE FROM barriers; DELETE FROM baseline;")?;
            self.set("reset_identity", &true)
        })
    }
    fn json_rows<T: DeserializeOwned>(&self, sql: &str) -> Result<Vec<T>> {
        let mut q = self.db.prepare(sql)?;
        let values: Vec<String> = q
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        values
            .iter()
            .map(|s| Ok(serde_json::from_str(s)?))
            .collect()
    }
    fn transaction<T>(&self, f: impl FnOnce() -> Result<T>) -> Result<T> {
        if !self.db.is_autocommit() {
            return f();
        }
        self.db.execute_batch("BEGIN IMMEDIATE")?;
        match f() {
            Ok(v) => {
                self.db.execute_batch("COMMIT")?;
                Ok(v)
            }
            Err(e) => {
                let _ = self.db.execute_batch("ROLLBACK");
                self.row_count_cache.set(None);
                *self.revision_cache.borrow_mut() = None;
                Err(e)
            }
        }
    }
}

#[cfg(test)]
mod performance_tests {
    use super::*;

    #[test]
    fn unchanged_capture_does_not_write_and_counts_follow_deletion_and_rollback() {
        let store = Store::memory(Identity::generate()).unwrap();
        store.create_group("test", "local").unwrap();
        let row = Row { key: Key::pinyin("sample", "ce shi").unwrap(), weight: 3 };
        store.capture(std::slice::from_ref(&row)).unwrap();
        assert!(store.prepare_apply().unwrap().is_none());
        assert_eq!(store.row_count().unwrap(), 1);
        let revision = store.revision().unwrap();
        let changes = store.db.total_changes();
        for _ in 0..5 {
            store.capture(std::slice::from_ref(&row)).unwrap();
            assert!(store.prepare_apply().unwrap().is_none());
            assert_eq!(store.row_count().unwrap(), 1);
            assert_eq!(store.revision().unwrap(), revision);
        }
        assert_eq!(store.db.total_changes(), changes, "unchanged capture wrote to SQLite");
        let failed: Result<()> = store.transaction(|| {
            store.capture(&[])?;
            assert_eq!(store.row_count()?, 0);
            assert_ne!(store.revision()?, revision);
            anyhow::bail!("simulate transaction failure")
        });
        assert!(failed.is_err());
        assert_eq!(store.row_count().unwrap(), 1);
        assert_eq!(store.revision().unwrap(), revision);
        store.capture(&[]).unwrap();
        assert_eq!(store.row_count().unwrap(), 0);
        assert!(store.baseline().unwrap().is_empty());
    }
}
