#!/usr/bin/env python3
"""
podman_prep.py — Generate podman-compose compatible YAML from standard compose files.

Fixes applied to every processed file:
  1. Services with profiles: [disabled] removed entirely
  2. depends_on: service_completed_successfully entries removed (podman-compose 1.x treats
     Exited(0) containers as failed, blocking all dependents of init/flyway-style services)
  3. restart: false → "no"  (podman-compose rejects Python booleans)
  4. tmpfs uid=/gid= stripped  (crun rejects these options in rootless mode)
  5. volumes + build contexts: relative paths → absolute  (podman-compose resolves
     relative paths from the first -f file's directory, not the file's own directory)
  6. environment: list → dict  (podman-compose fails to parse list format)

Usage:
    python3 podman_prep.py <source.yml> <output.podman.yml>
"""

import os
import sys
import yaml


_DISABLED_PROFILES = {"disabled", "donotstart"}
# Services that are always removed regardless of profiles.
# test-sftp-server: only needed during seeding; re-declared in docker-compose.podman.yml
#   with profiles: [seed] so it starts only via `make seed`.
_ALWAYS_REMOVE: set = {"test-sftp-server"}


def _absolutize_volumes(volumes: list, base_dir: str) -> list:
    """Convert relative host paths in volume entries to absolute paths.

    podman-compose resolves relative paths from the first -f file's directory,
    not from the compose file's own directory. Making paths absolute here
    ensures each file's bind mounts resolve correctly regardless of -f order.
    """
    result = []
    for v in volumes:
        if isinstance(v, str) and not v.startswith("/") and not v.startswith("~"):
            # Format: [host:]container[:options]
            # Only the host part (before the first colon that isn't a drive letter)
            # should be absolutized, and only if it looks like a path (starts with ./ or ../).
            parts = v.split(":", 1)
            host = parts[0]
            if host.startswith("./") or host.startswith("../") or host in (".", ".."):
                abs_host = os.path.normpath(os.path.join(base_dir, host))
                v = abs_host + (":" + parts[1] if len(parts) > 1 else "")
        result.append(v)
    return result


def process(src_path: str, dst_path: str) -> None:
    src_path = os.path.abspath(src_path)
    base_dir = os.path.dirname(src_path)

    with open(src_path) as f:
        data = yaml.safe_load(f)

    services = data.get("services") or {}

    # 1. Collect services that are gated behind a disabled profile so we can
    #    also scrub their names from other services' depends_on.
    disabled_services = {
        name
        for name, svc in services.items()
        if _DISABLED_PROFILES.intersection(set(svc.get("profiles") or []))
    }

    # 2. Remove disabled services and always-removed services entirely.
    to_remove = disabled_services | (_ALWAYS_REMOVE & set(services.keys()))
    for name in to_remove:
        del services[name]
    disabled_services = disabled_services | to_remove

    for svc_name, svc in services.items():
        # 3. Strip only service_completed_successfully depends_on entries.
        #    podman-compose 1.x treats any non-running container (including
        #    one-shot services like 'init' or 'flyway' that exit 0) as "failed",
        #    blocking all dependents. Strip only those entries; keep
        #    service_started and service_healthy (which work correctly since
        #    those dependencies stay running) so startup ordering is preserved.
        deps = svc.get("depends_on")
        if isinstance(deps, dict):
            filtered = {
                name: cond for name, cond in deps.items()
                if cond.get("condition") != "service_completed_successfully"
                and name not in disabled_services
            }
            if filtered:
                svc["depends_on"] = filtered
            else:
                svc.pop("depends_on", None)
        elif deps is not None:
            # List-form depends_on has no condition — keep as-is.
            pass

        # 4. Convert restart: false → restart: "no"
        #    podman-compose does not accept Python booleans as restart policies.
        if svc.get("restart") is False:
            svc["restart"] = "no"

        # 5. Strip unsupported uid=/gid= options from tmpfs entries.
        #    Rootless Podman/crun rejects "uid=N" in tmpfs mount options.
        if "tmpfs" in svc:
            tmpfs = svc["tmpfs"]
            if isinstance(tmpfs, list):
                cleaned = []
                for entry in tmpfs:
                    if isinstance(entry, str) and ":" in entry:
                        path, opts = entry.split(":", 1)
                        # Strip uid= and gid= options; keep the rest.
                        remaining = ",".join(
                            o for o in opts.split(",")
                            if not o.startswith("uid=") and not o.startswith("gid=")
                        )
                        entry = path if not remaining else f"{path}:{remaining}"
                    cleaned.append(entry)
                svc["tmpfs"] = cleaned

        # 6. Absolutize relative host paths in volumes and build contexts.
        #    podman-compose resolves relative paths from the first -f file's
        #    directory. Converting to absolute here ensures correct resolution.
        if isinstance(svc.get("volumes"), list):
            svc["volumes"] = _absolutize_volumes(svc["volumes"], base_dir)

        build = svc.get("build")
        if isinstance(build, dict):
            ctx = build.get("context", "")
            if isinstance(ctx, str) and (ctx.startswith("./") or ctx.startswith("../") or ctx in (".", "..")):
                build["context"] = os.path.normpath(os.path.join(base_dir, ctx))
        elif isinstance(build, str) and (build.startswith("./") or build.startswith("../") or build in (".", "..")):
            svc["build"] = os.path.normpath(os.path.join(base_dir, build))

        # 7. Convert environment list → dict.
        env = svc.get("environment")
        if isinstance(env, list):
            env_dict = {}
            for item in env:
                item = str(item)
                if "=" in item:
                    k, v = item.split("=", 1)
                    env_dict[k] = v
                else:
                    env_dict[item] = None
            svc["environment"] = env_dict

    with open(dst_path, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)

    print(f"  {src_path}  →  {dst_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <source.yml> <output.yml>")
        sys.exit(1)
    process(sys.argv[1], sys.argv[2])
