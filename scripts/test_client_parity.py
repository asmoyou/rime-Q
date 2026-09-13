#!/usr/bin/env python3
"""Fail when one native client drops an established product capability."""
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def text(*names: str) -> str:
    return "\n".join((ROOT / name).read_text(encoding="utf-8") for name in names)


def require(label: str, source: str, values: list[str]) -> None:
    missing = [value for value in values if value not in source]
    if missing:
        raise RuntimeError(f"{label} is missing: {', '.join(missing)}")


mac_shell = text("macos/Sources/SettingsWindow.swift", "macos/Sources/InputController.swift")
win_shell = text("windows/settings/SettingsWindow.cs", "windows/settings/Program.cs", "windows/tsf/service.cpp")
mac_personal = text("macos/Sources/DictionaryViews.swift", "macos/Sources/PersonalDictionary.swift")
win_personal = text("windows/settings/PersonalPage.cs", "windows/settings/Infrastructure.cs")
mac_resources = text("macos/Sources/DictionaryViews.swift", "macos/Sources/DictionaryResources.swift")
win_resources = text("windows/settings/ResourcesPage.cs", "windows/settings/DictionaryResources.cs")
mac_input = text("macos/Sources/SkinSettings.swift", "macos/Sources/ModelSettings.swift")
win_input = text("windows/settings/SettingsWindow.cs", "windows/settings/Infrastructure.cs")
mac_updates = text("macos/Sources/UpdateSettings.swift", "macos/Sources/UpdateChecker.swift")
win_updates = text("windows/settings/SettingsWindow.cs", "windows/settings/Infrastructure.cs")

pages = ["输入与外观", "个人词库", "词库与模型", "版本与更新", "皮肤"]
require("macOS settings navigation", mac_shell, pages)
require("Windows settings navigation", win_shell, pages)

personal = [
    "搜索词条或拼音", "按学习权重", "按词条", "按拼音", "新增", "编辑", "删除",
    "撤销", "导入", "导出", "查看备份", "还没有学习记录", "没有匹配的词条",
    "修改前", "备份", "已有新的学习或修改",
]
require("macOS personal dictionary", mac_personal, personal)
require("Windows personal dictionary", win_personal, personal)

resources = [
    "导入词库", "第三方词库", "停用", "启用", "移除", "查看词条", "导出源文件",
    "详细信息", "重新应用", "恢复内置", "正在编译词库", "个人学习记录", "原始导入文件",
]
require("macOS dictionary resources", mac_resources, resources)
require("Windows dictionary resources", win_resources, resources)

model = ["下载并开启", "取消", "移除万象模型", "基础输入", "学习记录"]
require("macOS optional model", mac_input, model)
require("Windows optional model", win_input, model)

require("macOS updates", mac_updates, ["自动检查更新", "检查更新", "查看发布记录", "没有发现更新", "暂时没有公开", "暂时无法检查"])
require("Windows updates", win_updates, ["自动检查更新", "检查更新", "查看发布记录", "没有更新", "尚无公开", "检查失败"])

menu = ["英文输入", "设置", "个人数据文件夹", "使用说明", "关于 Rime Q", "检查更新", "发现新版本", "卸载 Rime Q"]
require("macOS input menu", mac_shell, menu)
require("Windows input menus", win_shell, menu)
require("Windows TSF mode integration", win_shell, ["GUID_COMPARTMENT_KEYBOARD_OPENCLOSE", "GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION", "TF_MOD_CONTROL", "Rime Q 中英文状态"])

catalog = text("scripts/dictionary_catalog.py", "scripts/build_macos.py", "scripts/build_windows.py")
require("shared dictionary catalog", catalog, ["write_catalog", "write_windows_catalog", "dictionaries.json"])
lock_text = text("dependencies.lock.json")
if "windows_wanxiang_model" in lock_text:
    raise RuntimeError("Windows and macOS must not use separate model locks")
model = json.loads(lock_text)["wanxiang_model"]
windows_model = text("windows/settings/Infrastructure.cs", "windows/broker/engine.cpp")
require("Windows shared model lock", windows_model, [str(model["bytes"]), model["sha256"]])

print("PASS client parity contract: navigation, personal dictionary, resources, model, updates and menus")
