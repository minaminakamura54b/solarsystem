"""DJI Thermal SDK（dji_irp）の置き場所（2026-10-22 ユーザー指示で、実画像が無くても決められる部分だけ先に作る）。

- dji_irp のパスは環境変数 DJI_IRP_PATH（ハードコードしない）
- dji_irp が使う共有ライブラリの場所は DJI_IRP_LIB_DIR（省略時は dji_irp と同じディレクトリ）。
  呼び出すときは LD_LIBRARY_PATH の先頭に足す。実際のライブラリの置き場所は Phase S で確認する
- SDK は x86_64 Linux 向け。check() は SDK の機能を呼ばず、ファイルの有無・実行権限・ELF の種類だけを確かめる
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from pathlib import Path

ELF_MAGIC = b"\x7fELF"
ELF_MACHINES = {0x3E: "x86_64", 0xB7: "aarch64", 0x03: "x86"}


def irp_path(env: Mapping[str, str] = os.environ) -> str | None:
    return env.get("DJI_IRP_PATH") or None


def available(path: str | None) -> bool:
    return bool(path) and Path(path).is_file() and os.access(path, os.X_OK)


def library_dirs(path: str, env: Mapping[str, str] = os.environ) -> list[str]:
    return [env["DJI_IRP_LIB_DIR"]] if env.get("DJI_IRP_LIB_DIR") else [str(Path(path).parent)]


def subprocess_env(path: str, env: Mapping[str, str] = os.environ) -> dict[str, str]:
    """dji_irp を呼ぶときの環境変数（LD_LIBRARY_PATH の先頭に SDK のライブラリの場所を足す）。"""
    result = dict(env)
    paths = library_dirs(path, env) + [p for p in env.get("LD_LIBRARY_PATH", "").split(os.pathsep) if p]
    result["LD_LIBRARY_PATH"] = os.pathsep.join(paths)
    return result


def elf_machine(path: str) -> str:
    """実行ファイルの種類（x86_64 / aarch64 / x86 / other / not_elf）。ELF ヘッダだけを読む。"""
    with open(path, "rb") as f:
        header = f.read(20)
    if len(header) < 20 or header[:4] != ELF_MAGIC:
        return "not_elf"
    byteorder = "little" if header[5] == 1 else "big"
    return ELF_MACHINES.get(int.from_bytes(header[18:20], byteorder), "other")


def check(env: Mapping[str, str] = os.environ) -> dict:
    path = irp_path(env)
    report = {"dji_irp_path": path, "exists": False, "executable": False, "elf_machine": None,
              "library_dirs": [], "library_dirs_exist": False, "ok": False, "message": ""}
    if not path:
        report["message"] = "環境変数 DJI_IRP_PATH が設定されていません"
        return report
    report["exists"] = Path(path).is_file()
    report["executable"] = available(path)
    report["library_dirs"] = library_dirs(path, env)
    report["library_dirs_exist"] = all(Path(d).is_dir() for d in report["library_dirs"])
    if not report["exists"]:
        report["message"] = f"dji_irp が見つかりません: {path}"
        return report
    report["elf_machine"] = elf_machine(path)
    if not report["executable"]:
        report["message"] = "dji_irp に実行権限がありません"
    elif report["elf_machine"] != "x86_64":
        report["message"] = f"dji_irp が x86_64 Linux 向けではありません（{report['elf_machine']}）。linux/amd64 で動かしてください"
    elif not report["library_dirs_exist"]:
        report["message"] = f"SDK のライブラリのディレクトリがありません: {', '.join(report['library_dirs'])}"
    else:
        report["ok"] = True
        report["message"] = "dji_irp を使える状態です（SDK の機能は呼んでいません。温度行列が取れるかは Phase S で確認）"
    return report
