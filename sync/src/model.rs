use anyhow::{bail, ensure, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

// v2 carries native learning codes, not only dictionary-editor full syllables.
// The historical key namespace stays unchanged to preserve identity/deletions.
pub const PROTOCOL: u32 = 2;
pub const MAX_MEMBERS: usize = 128;
pub const MAX_ROWS: usize = 200_000;
pub const MAX_FRAME: usize = 4 * 1024 * 1024;
pub const MAX_BATCH: usize = 512;
pub type Vector = BTreeMap<String, u64>;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(deny_unknown_fields)]
pub struct Key {
    pub namespace: String,
    pub text: String,
    pub code: String,
}
impl Key {
    pub fn pinyin(text: &str, code: &str) -> Result<Self> {
        let key = Self {
            namespace: "rime_q/full-pinyin/v1".into(),
            text: text.trim().into(),
            code: code
                .replace('\'', " ")
                .split_whitespace()
                .map(str::to_owned)
                .collect::<Vec<_>>()
                .join(" "),
        };
        key.validate()?;
        Ok(key)
    }
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.namespace == "rime_q/full-pinyin/v1",
            "incompatible dictionary namespace"
        );
        ensure!(
            !self.text.is_empty()
                && !self.text.starts_with('#')
                && self.text.len() <= 1024
                && self.text.trim() == self.text
                && !self.text.chars().any(char::is_control),
            "invalid dictionary text"
        );
        ensure!(
            !self.code.is_empty()
                && self.code.len() <= 1024
                && !self.code.starts_with(' ')
                && !self.code.ends_with(' ')
                && !self.code.contains("  "),
            "invalid pinyin"
        );
        ensure!(
            self.code
                .bytes()
                .all(|c| c.is_ascii_alphabetic() || c == b' '),
            "unsupported pinyin"
        );
        Ok(())
    }
    // Keep the validation of already-signed v1 history unchanged.
    pub(crate) fn validate_legacy(&self) -> Result<()> {
        self.validate()?;
        static SYLLABLES: std::sync::OnceLock<std::collections::BTreeSet<&'static str>> =
            std::sync::OnceLock::new();
        let known =
            SYLLABLES.get_or_init(|| include_str!("../resources/pinyin.txt").lines().collect());
        ensure!(
            self.code.split(' ').all(|s| s.len() <= 16
                && (known.contains(s) || s.bytes().all(|c| c.is_ascii_uppercase()))),
            "invalid syllable"
        );
        Ok(())
    }
    pub fn id(&self) -> String {
        format!("{}\t{}\t{}", self.namespace, self.text, self.code)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Row {
    pub key: Key,
    pub weight: u32,
}
impl Row {
    pub fn validate(&self) -> Result<()> {
        self.key.validate()?;
        ensure!(self.weight < i32::MAX as u32, "invalid weight");
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Change {
    pub key: Key,
    pub weight: Option<u32>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Operation {
    pub protocol: u32,
    pub group: String,
    pub origin: String,
    pub seq: u64,
    pub context: Vector,
    pub changes: Vec<Change>,
    pub signature: String,
}
impl Operation {
    pub fn signing_bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(&(
            "RimeQ.operation.v1",
            self.protocol,
            &self.group,
            &self.origin,
            self.seq,
            &self.context,
            &self.changes,
        ))?)
    }
    pub fn validate(&self) -> Result<()> {
        ensure!(
            (self.protocol == 1 || self.protocol == PROTOCOL) && self.seq > 0 && self.seq < i64::MAX as u64,
            "invalid protocol or sequence"
        );
        ensure!(
            self.context.len() <= MAX_MEMBERS
                && self.context.values().all(|v| *v < i64::MAX as u64),
            "invalid context"
        );
        ensure!(
            self.context.get(&self.origin).copied().unwrap_or(0) + 1 == self.seq,
            "sequence gap in origin context"
        );
        ensure!(
            !self.changes.is_empty() && self.changes.len() <= MAX_BATCH,
            "invalid change count"
        );
        let mut unique = std::collections::BTreeSet::new();
        for c in &self.changes {
            if self.protocol == 1 { c.key.validate_legacy()?; } else { c.key.validate()?; }
            ensure!(
                c.weight.is_none_or(|w| w < i32::MAX as u32),
                "invalid weight"
            );
            ensure!(unique.insert(c.key.id()), "duplicate key in operation");
        }
        Ok(())
    }
}

pub fn covers(a: &Vector, b: &Vector) -> bool {
    b.iter().all(|(k, v)| a.get(k).copied().unwrap_or(0) >= *v)
}

pub fn parse_tsv(text: &str) -> Result<Vec<Row>> {
    ensure!(text.len() <= 32 * 1024 * 1024, "dictionary too large");
    let mut rows: BTreeMap<Key, u32> = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        if line.is_empty() {
            continue;
        }
        if line.starts_with('#') {
            if let Some(dict) = line.strip_prefix("#@/db_name\t") {
                ensure!(dict == "rime_q", "incompatible dictionary");
            }
            continue;
        }
        let cols: Vec<_> = line.split('\t').collect();
        ensure!((2..=3).contains(&cols.len()), "invalid dictionary columns");
        let key = Key::pinyin(cols[0], cols[1])?;
        let weight = if cols.len() == 3 {
            cols[2].trim().parse::<i64>()?
        } else {
            1
        };
        if weight < 0 {
            continue;
        } // Native exports can include internal deletion markers.
        ensure!(weight < i32::MAX as i64, "invalid weight");
        let value = rows.entry(key).or_insert(0);
        *value = (*value).max(weight as u32);
        if rows.len() > MAX_ROWS {
            bail!("dictionary capacity exceeded");
        }
    }
    Ok(rows
        .into_iter()
        .map(|(key, weight)| Row { key, weight })
        .collect())
}

pub fn tsv(rows: &[Row]) -> String {
    let mut result = String::from("# Rime Q personal dictionary\n#@/db_name\trime_q\n");
    for row in rows {
        result.push_str(&format!(
            "{}\t{}\t{}\n",
            row.key.text, row.key.code, row.weight
        ));
    }
    result
}
