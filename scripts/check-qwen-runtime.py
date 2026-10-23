#!/usr/bin/env python3
"""检查 Qwen 插件的计算库归属，以及 Mach-O 依赖中的 MLX 路径。"""

import hashlib
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def inspect(binary):
    dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    libraries = [line.strip().split(" (compatibility version", 1)[0]
                 for line in dependencies.splitlines()[1:] if line.startswith("\t")]
    rpaths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", commands)
    return libraries, rpaths


def check(app):
    app = app.resolve()
    contents = app / "Contents"
    plugin = contents / "PlugIns/Qwen3Plugin.bundle/Contents"
    kernel = plugin / "MacOS/mlx.metallib"
    resource = plugin / "Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
    binary = plugin / "MacOS/Qwen3Plugin"
    for path in [kernel, resource, binary]:
        if not path.is_file() or not path.resolve().is_relative_to(app):
            raise ValueError(f"Qwen 计算库或可执行文件缺失，或指向应用外部：{path}")
    digest = hashlib.sha256(kernel.read_bytes()).hexdigest()
    if digest != hashlib.sha256(resource.read_bytes()).hexdigest():
        raise ValueError("Qwen 同目录计算库与本次构建的 MLX 资源不一致")
    with (contents / "Info.plist").open("rb") as file:
        executable = contents / "MacOS" / plistlib.load(file)["CFBundleExecutable"]
    _, executable_rpaths = inspect(executable)

    def expand(path, loader):
        return Path(path.replace("@loader_path", str(loader.parent))
                    .replace("@executable_path", str(executable.parent))).resolve()

    queue, seen, mlx_dependencies = [binary], set(), set()
    while queue:
        loader = queue.pop().resolve()
        if loader in seen:
            continue
        seen.add(loader)
        libraries, rpaths = inspect(loader)
        for library in libraries:
            if library.startswith(("/System/Library/", "/usr/lib/")):
                continue
            if library.startswith("@rpath/"):
                roots = [expand(path, loader) for path in rpaths]
                roots += [expand(path, executable) for path in executable_rpaths]
                candidates = [root / library.removeprefix("@rpath/") for root in roots]
            else:
                candidates = [expand(library, loader)]
            existing = [path.resolve() for path in candidates if path.is_file()]
            if re.search(r"(?:^|/)(?:lib)?c?mlx[^/]*(?:/|$)", library, re.IGNORECASE):
                mlx_dependencies.add(library)
                if not existing or any(not path.is_relative_to(app) for path in existing):
                    raise ValueError(f"MLX 动态库无法限定在应用内部：{loader} → {library} → {existing}")
            queue.extend(existing)
    print(f"Qwen runtime PASS: metallib={kernel}; sha256={digest}; dynamicMLXDependencies={len(mlx_dependencies)}")


if __name__ == "__main__":
    try:
        check(Path(sys.argv[1]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
