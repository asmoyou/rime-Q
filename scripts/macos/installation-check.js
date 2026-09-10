// Installer's embedded JavaScript: read-only checks before authentication.
var rimeqPackageVersion = "@PACKAGE_VERSION@";
var rimeqPackageBuild = "@PACKAGE_BUILD@";
var rimeqCachedPlan = null;

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
    if (rimeqCachedPlan) return rimeqCachedPlan;
    var path = "/Library/Input Methods/RimeQ.app";
    if (!system.files.fileExistsAtPath(path)) return rimeqCachedPlan = {action: "install"};
    var info;
    try { info = system.files.plistAtPath(path + "/Contents/Info.plist"); }
    catch (error) { return rimeqCachedPlan = {action: "invalid"}; }
    if (!info || info.CFBundleIdentifier !== "com.asmoyou.inputmethod.RimeQ") {
        return rimeqCachedPlan = {action: "conflict"};
    }
    var releaseOrder = rimeqCompareVersions(info.CFBundleShortVersionString, rimeqPackageVersion);
    var buildOrder = rimeqCompareVersions(info.CFBundleVersion, rimeqPackageBuild);
    var action = "invalid";
    if (releaseOrder !== null && buildOrder !== null) {
        if (releaseOrder > 0 || (releaseOrder === 0 && buildOrder > 0)) action = "downgrade";
        else action = releaseOrder < 0 ? "upgrade" : "repair";
    }
    return rimeqCachedPlan = {action: action, version: info.CFBundleShortVersionString, build: info.CFBundleVersion};
}

function rimeqActionIs(action) { return rimeqInstallPlan().action === action; }

function rimeqCheckInstallation() {
    var plan = rimeqInstallPlan();
    if (plan.action === "install" || plan.action === "upgrade" || plan.action === "repair") return true;
    my.result.type = "Fatal";
    if (plan.action === "downgrade") {
        my.result.title = "已安装较新的 Rime Q";
        my.result.message = "当前版本 " + plan.version + "（构建 " + plan.build + "），本安装包为 " +
            rimeqPackageVersion + "（构建 " + rimeqPackageBuild + "）。请选择相同或更新的安装包。";
    } else {
        my.result.title = "无法确认当前安装";
        my.result.message = "系统输入法目录中的 RimeQ.app 无法识别或属于其他应用。请先检查该应用，安装器不会覆盖它。";
    }
    return false;
}
