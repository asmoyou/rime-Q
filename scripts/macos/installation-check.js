// Installer's embedded JavaScript: read-only checks before authentication.
var rimeqPackageVersion = "@PACKAGE_VERSION@";
var rimeqPackageBuild = "@PACKAGE_BUILD@";

function rimeqCompareVersions(left, right) {
    if (!/^[0-9]+(\.[0-9]+){0,2}$/.test(String(left)) ||
        !/^[0-9]+(\.[0-9]+){0,2}$/.test(String(right))) return null;
    var a = String(left).split(".");
    var b = String(right).split(".");
    for (var i = 0; i < 3; i++) {
        var av = i < a.length ? Number(a[i]) : 0;
        var bv = i < b.length ? Number(b[i]) : 0;
        if (av !== bv) return av < bv ? -1 : 1;
    }
    return 0;
}

function rimeqInstallPlan() {
    var path = "/Library/Input Methods/RimeQ.app";
    if (!system.files.fileExistsAtPath(path)) return {action: "install"};
    var info;
    try { info = system.files.plistAtPath(path + "/Contents/Info.plist"); }
    catch (error) { return {action: "invalid"}; }
    if (!info || info.CFBundleIdentifier !== "com.asmoyou.inputmethod.RimeQ") {
        return {action: "conflict"};
    }
    var releaseOrder = rimeqCompareVersions(info.CFBundleShortVersionString, rimeqPackageVersion);
    var buildOrder = rimeqCompareVersions(info.CFBundleVersion, rimeqPackageBuild);
    var action = "invalid";
    if (releaseOrder !== null && buildOrder !== null) {
        if (releaseOrder > 0 || (releaseOrder === 0 && buildOrder > 0)) action = "downgrade";
        else action = releaseOrder < 0 ? "upgrade" : (buildOrder < 0 ? "update" : "current");
    }
    return {action: action, version: info.CFBundleShortVersionString, build: info.CFBundleVersion};
}

function rimeqActionIs(action) { return rimeqInstallPlan().action === action; }

function rimeqCheckInstallation() {
    var plan = rimeqInstallPlan();
    if (plan.action === "install" || plan.action === "upgrade" || plan.action === "update") return true;
    my.result.type = "Fatal";
    if (plan.action === "current") {
        my.result.title = "已安装最新版 Rime Q";
        my.result.message = "已安装本安装包提供的版本 " + plan.version + "（构建 " + plan.build + "），无需重复安装。此提示仅比较本地安装包，不代表已检查在线更新。";
    } else if (plan.action === "downgrade") {
        my.result.title = "已安装较新的 Rime Q";
        my.result.message = "当前版本 " + plan.version + "（构建 " + plan.build + "），本安装包为 " +
            rimeqPackageVersion + "（构建 " + rimeqPackageBuild + "）。请选择相同或更新的安装包。";
    } else {
        my.result.title = "无法确认当前安装";
        my.result.message = "系统输入法目录中的 RimeQ.app 无法识别或属于其他应用。请先检查该应用，安装器不会覆盖它。";
    }
    return false;
}
