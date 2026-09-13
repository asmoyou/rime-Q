use rimeq_sync::{
    identity::Identity,
    model::{Change, Key},
    store::Store,
};

fn nodes(n: usize) -> Vec<Store> {
    let result: Vec<_> = (0..n)
        .map(|_| Store::memory(Identity::generate()).unwrap())
        .collect();
    result[0].create_group("test group", "A").unwrap();
    for i in 1..n {
        let grant = result[0]
            .grant(&result[i].id(), &format!("device-{i}"))
            .unwrap();
        let group = result[0].group().unwrap();
        result[i].join_group(group, grant).unwrap();
    }
    for i in 1..n {
        let members = result[0].members().unwrap();
        result[i].merge_members(&members).unwrap();
    }
    result
}
fn change(text: &str, weight: Option<u32>) -> Change {
    Change {
        key: Key::pinyin(text, "ce shi").unwrap(),
        weight,
    }
}
fn transfer(nodes: &mut [Store], a: usize, b: usize) {
    let operations = nodes[a].missing(&nodes[b].vector().unwrap(), 512).unwrap();
    nodes[b].receive(&operations).unwrap();
}
fn converge(nodes: &mut [Store]) {
    for _ in 0..nodes.len() + 1 {
        for i in 0..nodes.len() {
            transfer(nodes, i, (i + 1) % nodes.len());
        }
    }
}

#[test]
fn six_devices_relay_and_duplicate_delivery() {
    let mut nodes = nodes(6);
    for (i, node) in nodes.iter_mut().enumerate() {
        node.change(vec![change(&format!("词条{i}"), Some(i as u32 + 1))])
            .unwrap();
    }
    converge(&mut nodes);
    let expected = nodes[0].rows().unwrap();
    assert_eq!(expected.len(), 6);
    for node in &nodes {
        assert_eq!(node.rows().unwrap(), expected);
    }
    converge(&mut nodes);
    for node in &nodes {
        assert_eq!(node.rows().unwrap(), expected);
    }
}
#[test]
fn deletion_beats_offline_learning_but_allows_causal_relearning() {
    let mut nodes = nodes(6);
    nodes[0].change(vec![change("测试", Some(10))]).unwrap();
    converge(&mut nodes);
    nodes[0].change(vec![change("测试", None)]).unwrap();
    nodes[5].change(vec![change("测试", Some(200))]).unwrap();
    converge(&mut nodes);
    for node in &nodes {
        assert!(node.rows().unwrap().is_empty());
    }
    nodes[3].change(vec![change("测试", Some(1))]).unwrap();
    converge(&mut nodes);
    for node in &nodes {
        assert_eq!(node.rows().unwrap()[0].weight, 1);
    }
}
#[test]
fn concurrent_weights_use_max_and_explicit_lowering_propagates() {
    let mut nodes = nodes(6);
    for (i, node) in nodes.iter_mut().enumerate() {
        node.change(vec![change("测试", Some(10 + i as u32))])
            .unwrap();
    }
    converge(&mut nodes);
    for node in &nodes {
        assert_eq!(node.rows().unwrap()[0].weight, 15);
    }
    nodes[4].change(vec![change("测试", Some(2))]).unwrap();
    converge(&mut nodes);
    for node in &nodes {
        assert_eq!(node.rows().unwrap()[0].weight, 2);
    }
}
#[test]
fn gaps_do_not_advance_confirmed_watermark_and_bad_signatures_are_atomic() {
    let nodes = nodes(2);
    nodes[0].change(vec![change("甲", Some(1))]).unwrap();
    nodes[0].change(vec![change("乙", Some(2))]).unwrap();
    let ops = nodes[0].missing(&Default::default(), 512).unwrap();
    nodes[1].receive(&ops[1..]).unwrap();
    assert!(nodes[1].vector().unwrap().is_empty());
    let mut bad = ops[0].clone();
    bad.changes[0].weight = Some(123);
    assert!(nodes[1].receive(&[ops[0].clone(), bad]).is_err());
    assert!(nodes[1].vector().unwrap().is_empty());
    nodes[1].receive(&ops[..1]).unwrap();
    assert_eq!(nodes[1].rows().unwrap().len(), 2);
}

#[test]
fn late_pre_delete_weight_does_not_override_a_new_generation() {
    let mut nodes = nodes(3);
    nodes[0].change(vec![change("测试", Some(10))]).unwrap();
    converge(&mut nodes);
    nodes[2].change(vec![change("测试", Some(200))]).unwrap();
    nodes[0].change(vec![change("测试", None)]).unwrap();
    transfer(&mut nodes, 0, 1);
    nodes[1].change(vec![change("测试", Some(1))]).unwrap();
    transfer(&mut nodes, 2, 1);
    converge(&mut nodes);
    for node in &nodes {
        assert_eq!(node.rows().unwrap()[0].weight, 1);
    }
}

#[test]
fn removal_authority_and_old_grants_converge_in_any_order() {
    let nodes = nodes(6);
    // A device may invite once; every other device trusts that signed grant.
    let guest = Store::memory(Identity::generate()).unwrap();
    let grant = nodes[1].grant(&guest.id(), "guest").unwrap();
    guest
        .enroll(
            nodes[0].group().unwrap(),
            grant,
            &nodes[1].members().unwrap(),
            &[],
        )
        .unwrap();
    nodes[0]
        .merge_members(&nodes[1].members().unwrap())
        .unwrap();
    assert!(nodes[1].revoke(&nodes[3].id()).is_err());
    let first = nodes[0].revoke(&nodes[1].id()).unwrap();
    let second = nodes[0].revoke(&nodes[2].id()).unwrap();
    for node in &nodes[3..] {
        node.merge_members(&nodes[0].members().unwrap()).unwrap();
    }
    nodes[3]
        .merge_revocations(&[first.clone(), second.clone()])
        .unwrap();
    nodes[4]
        .merge_revocations(&[second.clone(), first.clone()])
        .unwrap();
    nodes[5].merge_revocations(&[second]).unwrap();
    nodes[5].merge_revocations(&[first]).unwrap();
    for node in &nodes[3..] {
        assert!(!node.authorized(&nodes[1].id()).unwrap());
        assert!(node.authorized(&guest.id()).unwrap());
        assert_eq!(node.revision().unwrap(), nodes[3].revision().unwrap());
    }
    // An unaware removed issuer can still sign, but a receiver must roll back
    // new grants rather than consuming member capacity or admitting the guest.
    let outsider = Identity::generate();
    nodes[1].grant(&outsider.id(), "late guest").unwrap();
    let before = nodes[3].members().unwrap();
    assert!(nodes[3]
        .merge_members(&nodes[1].members().unwrap())
        .is_err());
    assert_eq!(before, nodes[3].members().unwrap());
}

#[test]
fn durable_apply_requires_exact_readback_and_binds_membership_revision() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("state.sqlite");
    let identity = Identity::load(dir.path(), true).unwrap();
    let local = Store::open(&path, identity).unwrap();
    local.create_group("durability", "local").unwrap();
    local.capture(&[]).unwrap();
    local.change(vec![change("恢复词", Some(8))]).unwrap();
    let job = local.prepare_apply().unwrap().unwrap();
    drop(local);
    let local = Store::open(&path, Identity::load(dir.path(), true).unwrap()).unwrap();
    assert_eq!(local.prepare_apply().unwrap().unwrap().id, job.id);
    assert!(local.acknowledge(&job.id, &[]).is_err());
    assert!(local
        .acknowledge(&job.id, &[job.after[0].clone(), job.after[0].clone()])
        .is_err());
    local
        .grant(&Identity::generate().id(), "new member")
        .unwrap();
    local.acknowledge(&job.id, &job.after).unwrap();
    assert_ne!(
        local.get::<String>("applied_revision").unwrap().unwrap(),
        local.revision().unwrap()
    );
    assert!(local.prepare_apply().unwrap().is_none());
    assert_eq!(
        local.get::<String>("applied_revision").unwrap().unwrap(),
        local.revision().unwrap()
    );
}

#[test]
fn explicit_recovery_preserves_current_local_edits_and_archives_on_leave() {
    let dir = tempfile::tempdir().unwrap();
    let local = Store::open(&dir.path().join("state.sqlite"), Identity::generate()).unwrap();
    local.create_group("recovery", "local").unwrap();
    local.capture(&[]).unwrap();
    local.change(vec![change("远端修改", Some(9))]).unwrap();
    let job = local.prepare_apply().unwrap().unwrap();
    let actual = vec![rimeq_sync::model::Row {
        key: Key::pinyin("本机新词", "ce shi").unwrap(),
        weight: 3,
    }];
    local.recover_local(&job.id, &actual).unwrap();
    assert_eq!(local.rows().unwrap(), actual);
    assert!(local.prepare_apply().unwrap().is_none());
    let archive = dir.path().join("archive.sqlite");
    local.leave(&archive).unwrap();
    assert!(local
        .get::<rimeq_sync::store::Group>("group")
        .unwrap()
        .is_none());
    assert!(local.get::<bool>("reset_identity").unwrap().unwrap());
    let saved = Store::open(&archive, Identity::generate()).unwrap();
    assert_eq!(saved.rows().unwrap(), actual);
}

#[test]
fn network_batches_stay_below_frame_limit_without_loading_all_history() {
    let nodes = nodes(2);
    for i in 0..24 {
        nodes[0]
            .change(
                (0..512)
                    .map(|j| change(&format!("{}-{i}-{j}", "长".repeat(150)), Some(1)))
                    .collect(),
            )
            .unwrap();
    }
    let first = nodes[0].missing(&Default::default(), 512).unwrap();
    assert!(first.len() < 24);
    assert!(serde_json::to_vec(&first).unwrap().len() <= rimeq_sync::model::MAX_FRAME);
    for _ in 0..24 {
        let batch = nodes[0].missing(&nodes[1].vector().unwrap(), 512).unwrap();
        if batch.is_empty() {
            break;
        }
        nodes[1].receive(&batch).unwrap();
    }
    assert_eq!(nodes[1].vector().unwrap(), nodes[0].vector().unwrap());
}

#[test]
fn native_capture_must_not_treat_received_deletion_as_engine_observed() {
    let mut nodes = nodes(3);
    let initial = vec![rimeq_sync::model::Row {
        key: Key::pinyin("旧学习", "ce shi").unwrap(),
        weight: 10,
    }];
    nodes[0].capture(&initial).unwrap();
    assert!(nodes[0].prepare_apply().unwrap().is_none());
    converge(&mut nodes);
    nodes[1].capture(&[]).unwrap();
    let job = nodes[1].prepare_apply().unwrap().unwrap();
    nodes[1].acknowledge(&job.id, &job.after).unwrap();
    nodes[0].capture(&[]).unwrap();
    assert!(nodes[0].prepare_apply().unwrap().is_none());
    transfer(&mut nodes, 0, 1);
    // The real engine learned while offline; helper received a deletion before
    // it had an idle opportunity to export those pre-existing local changes.
    let mut offline = initial.clone();
    offline[0].weight = 900;
    nodes[1].capture(&offline).unwrap();
    let deletion = nodes[1].prepare_apply().unwrap().unwrap();
    assert!(deletion.after.is_empty());
    nodes[1].acknowledge(&deletion.id, &[]).unwrap();
    let mut relearned = initial;
    relearned[0].weight = 1;
    nodes[1].capture(&relearned).unwrap();
    assert!(nodes[1].prepare_apply().unwrap().is_none());
    converge(&mut nodes);
    assert_eq!(nodes[2].rows().unwrap(), relearned);
}

#[cfg(target_os = "macos")]
#[test]
fn obsolete_identity_resets_pairing_without_touching_personal_data() {
    use rimeq_sync::identity::atomic_write;
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().join("sync");
    std::fs::create_dir(&root).unwrap();
    let personal = directory.path().join("personal-dictionary-sentinel");
    std::fs::write(&personal, b"native dictionary stays intact").unwrap();
    let original = Store::open(&root.join("state.sqlite"), Identity::generate()).unwrap();
    let old_id = original.id();
    let old_group = original
        .create_group("unreleased group", "old device")
        .unwrap();
    original.change(vec![change("旧同步词", Some(8))]).unwrap();
    atomic_write(&root.join("identity.key"), b"keychain-v1").unwrap();
    drop(original);
    let reset = Store::load(&root, false).unwrap();
    assert_ne!(reset.id(), old_id);
    assert!(reset.group().is_err());
    assert!(!reset.enabled());
    assert!(reset.rows().unwrap().is_empty());
    let new_id = reset.id();
    drop(reset);
    let reloaded = Store::load(&root, false).unwrap();
    assert_eq!(reloaded.id(), new_id);
    let archive = std::fs::read_dir(root.join("archives"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let saved = Store::open(&archive, Identity::generate()).unwrap();
    assert_eq!(saved.group().unwrap().id, old_group.id);
    assert_eq!(saved.rows().unwrap().len(), 1);
    assert_eq!(
        std::fs::read(personal).unwrap(),
        b"native dictionary stays intact"
    );
    reloaded.create_group("new group", "new device").unwrap();
}

#[test]
fn interrupted_identity_reset_finishes_before_sync_can_resume() {
    let root = tempfile::tempdir().unwrap();
    let store = Store::load(root.path(), true).unwrap();
    let old_id = store.id();
    store.create_group("test", "test").unwrap();
    store
        .leave(&root.path().join("before-reset.sqlite"))
        .unwrap();
    drop(store);
    let store = Store::load(root.path(), true).unwrap();
    assert_ne!(store.id(), old_id);
    assert!(store.group().is_err());
    assert!(store.get::<bool>("reset_identity").unwrap().is_none());
    let new_id = store.id();
    drop(store);
    assert_eq!(Store::load(root.path(), true).unwrap().id(), new_id);
}
