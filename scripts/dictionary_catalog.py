"""Build the resource inventory from the exact files shipped in the app."""
import hashlib
import json
from pathlib import Path


def write_catalog(contents: Path, lock: dict):
    shared = contents / "SharedSupport"
    ice_revision = lock["rime_ice"]["revision"]
    definitions = [
        ("cn_dicts/8105", "常用字与读音", "cn_dicts/8105.dict.yaml", False, "chinese"),
        ("cn_dicts/base", "基础词库", "cn_dicts/base.dict.yaml", False, "chinese"),
        ("cn_dicts/ext", "扩展词库", "cn_dicts/ext.dict.yaml", True, "chinese"),
        ("cn_dicts/tencent", "腾讯整理词表", "cn_dicts/tencent.dict.yaml", True, "chinese"),
        ("cn_dicts/others", "其他补充词表", "cn_dicts/others.dict.yaml", True, "chinese"),
        ("english", "英文词库", "en_dicts/en.dict.yaml", False, "support"),
        ("english_ext", "英文扩展词库", "en_dicts/en_ext.dict.yaml", False, "support"),
        ("mixed", "中英混输词表", "en_dicts/cn_en.txt", False, "support"),
        ("radical", "拆字查询词库", "radical_pinyin.dict.yaml", False, "support"),
        ("wanxiang", "万象语法模型", "wanxiang-lts-zh-hans.gram", False, "model"),
    ]
    result = []
    for resource_id, name, relative, optional, kind in definitions:
        if kind == "model":
            model = lock["wanxiang_model"]
            result.append(dict(id=resource_id, name=name, file=relative, count=0,
                bytes=model["bytes"], sha256=model["sha256"], optional=False, kind=kind,
                source="https://github.com/amzxyz/RIME-LMDG", version="LTS · " + model["sha256"][:12],
                license="CC-BY-4.0 · amzxyz"))
            continue
        path = shared / relative
        if not path.exists():
            raise RuntimeError(f"Bundled resource missing: {relative}")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        count = 0
        if kind != "model":
            body = not relative.endswith(".yaml")
            with path.open(encoding="utf-8-sig") as stream:
                for line in stream:
                    if line.strip() == "...":
                        body = True
                        continue
                    if body and line.strip() and not line.startswith("#"):
                        count += 1
        model = kind == "model"
        result.append(dict(id=resource_id, name=name, file=relative, count=count,
            bytes=path.stat().st_size, sha256=digest.hexdigest(), optional=optional, kind=kind,
            source="https://github.com/amzxyz/RIME-LMDG" if model else "https://github.com/iDvel/rime-ice",
            version="LTS · " + digest.hexdigest()[:12] if model else ice_revision[:12],
            license="CC-BY-4.0 · amzxyz" if model else "随雾凇分发；各词表原始声明保留在源文件中"))
    (contents / "Resources/dictionaries.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
