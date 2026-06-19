local Sysroot = import("../sysroot/install.nut")

function apply(index, status, source_uri, plan, logger = null) {
    local tx = Sysroot.SysrootTransaction(index, status, source_uri, logger)
    if (plan.action == "install") return tx.install(plan)
    if (plan.action == "remove") return tx.remove(plan)
    if (plan.action == "cleanup") return tx.cleanup(plan)
    throw "unsupported transaction action: " + plan.action
}

async function apply_async(index, status, source_uri, plan, logger = null, progress = null) {
    local tx = Sysroot.SysrootTransaction(index, status, source_uri, logger, progress)
    if (plan.action == "install") return await tx.install_async(plan)
    if (plan.action == "remove") return await tx.remove_async(plan)
    if (plan.action == "cleanup") return await tx.cleanup_async(plan)
    throw "unsupported transaction action: " + plan.action
}

return {
    apply = apply,
    apply_async = apply_async,
}
