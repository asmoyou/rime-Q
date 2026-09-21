use rimeq_sync::{identity::Identity, model::{parse_tsv, tsv, Key, Row}, store::Store};
use rimeq_sync::model::{Change, Operation, PROTOCOL};
use rimeq_sync::store::ApplyJob;
use std::collections::BTreeMap;

#[test]
fn native_learning_codes_round_trip_without_rewriting() {
    let codes = ["amazon", "u", "uig", "gocheng", "iPhone", "NASA", "internationalization", "ni hao"];
    let source = codes.iter().enumerate().map(|(i,c)| format!("Synthetic{i}\t{c}\t{}\n",i+1)).collect::<String>();
    let rows = parse_tsv(&source).unwrap();
    assert_eq!(rows.iter().map(|r|r.key.code.as_str()).collect::<Vec<_>>(), codes);
    assert_eq!(parse_tsv(&tsv(&rows)).unwrap(), rows);
    let store = Store::memory(Identity::generate()).unwrap();
    store.create_group("synthetic", "A").unwrap();
    store.capture(&rows).unwrap();
    assert!(store.prepare_apply().unwrap().is_none());
    assert_eq!(store.rows().unwrap(), rows);
}

#[test]
fn signed_v1_history_and_group_survive_storage_upgrade() {
    let root=tempfile::tempdir().unwrap();
    let source=Store::load(root.path(),true).unwrap();
    let peer=Store::memory(Identity::generate()).unwrap();
    let group=source.create_group("Synthetic","A").unwrap();
    let grant=source.grant(&peer.id(),"B").unwrap();
    peer.join_group(group.clone(),grant).unwrap();
    peer.merge_members(&source.members().unwrap()).unwrap();
    let mut old=Operation {protocol:1,group:group.id.clone(),origin:source.id(),seq:1,context:BTreeMap::new(),
        changes:vec![Change {key:Key::pinyin("SyntheticLegacy","ce shi").unwrap(),weight:Some(7)}],signature:String::new()};
    old.signature=source.identity.sign(&old.signing_bytes().unwrap());
    source.receive(&[old.clone()]).unwrap();peer.receive(&[old.clone()]).unwrap();
    let id=source.id();drop(source);
    let db=rusqlite::Connection::open(root.path().join("state.sqlite")).unwrap();
    db.execute_batch("PRAGMA user_version=1").unwrap();drop(db);
    let source=Store::load(root.path(),true).unwrap();
    assert_eq!(source.id(),id);assert_eq!(source.group().unwrap(),group);
    assert_eq!(source.missing(&BTreeMap::new(),512).unwrap(),vec![old.clone()]);
    let native=Key::pinyin("SyntheticNative","iPhone").unwrap();
    source.change(vec![Change {key:native.clone(),weight:Some(19)}]).unwrap();
    let added=source.missing(&peer.vector().unwrap(),512).unwrap();
    assert_eq!(added[0].protocol,PROTOCOL);peer.receive(&added).unwrap();
    assert_eq!(peer.rows().unwrap(),source.rows().unwrap());
    source.change(vec![Change {key:native,weight:None}]).unwrap();
    peer.receive(&source.missing(&peer.vector().unwrap(),512).unwrap()).unwrap();
    assert_eq!(peer.rows().unwrap().len(),1);
    old.changes[0].key.code="amazon".into();
    assert!(old.validate().is_err(),"v1 validation was silently widened");
    let db=rusqlite::Connection::open(root.path().join("state.sqlite")).unwrap();
    assert_eq!(db.query_row("PRAGMA user_version",[],|r|r.get::<_,u32>(0)).unwrap(),2);
}

#[test]
fn v1_pending_upgrade_keeps_excluded_learning_and_remote_changes() {
    for already_applied in [false,true] {
        let store=Store::memory(Identity::generate()).unwrap();store.create_group("Synthetic","A").unwrap();
        let old=Row {key:Key::pinyin("Legacy","ce shi").unwrap(),weight:7};
        let native=Row {key:Key::pinyin("Native","amazon").unwrap(),weight:19};
        store.capture(&[old.clone()]).unwrap();store.prepare_apply().unwrap();
        store.change(vec![Change {key:old.key.clone(),weight:Some(11)}]).unwrap();
        let pending=store.prepare_apply().unwrap().unwrap();
        let mut legacy=serde_json::to_value(&pending).unwrap();legacy.as_object_mut().unwrap().remove("protocol");
        store.set("apply_job",&legacy).unwrap();
        let mut actual=if already_applied {pending.after.clone()} else {pending.before.clone()};actual.push(native.clone());
        assert!(store.upgrade_pending(&actual).unwrap());
        if let Some(job)=store.get::<ApplyJob>("apply_job").unwrap() {
            assert_eq!(job.protocol,PROTOCOL);
            assert!(job.before.contains(&native)&&job.after.contains(&native));
            store.acknowledge(&job.id,&job.after).unwrap();
        }
        assert!(store.rows().unwrap().contains(&native));
        assert_eq!(store.rows().unwrap().iter().find(|r|r.key==old.key).unwrap().weight,11);
        assert_eq!(store.baseline().unwrap(),store.rows().unwrap());
    }
}

#[test]
fn native_codes_still_reject_injection_and_oversize() {
    for code in ["", "ni\thao", "ni\nhao", "ni;hao", "ni/hao", "ni1", "你", " ni", "ni ", "ni  hao"] {
        let key = Key {namespace:"rime_q/full-pinyin/v1".into(),text:"Synthetic".into(),code:code.into()};
        assert!(key.validate().is_err(),"accepted {code:?}");
    }
    assert!(Key::pinyin("Synthetic", &"a".repeat(1025)).is_err());
    assert!(Key::pinyin("Injected\nrow", "amazon").is_err());
    assert!(Row {key:Key::pinyin("Synthetic","amazon").unwrap(),weight:i32::MAX as u32}.validate().is_err());
}
