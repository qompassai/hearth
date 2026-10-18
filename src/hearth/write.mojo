"""Write stage (SPEC.md S5): materialize the output tree atomically.

All files are written to a sibling temp directory first; only when every
write succeeded is the temp tree swapped into place via rename(2) (the
stdlib has no rename, so it is one libc call through the FFI — verified
on the pinned toolchain). A failed build therefore never leaves a
half-written site: the previous output, if any, stays untouched.
"""

from hearth.assets import OutputFile
from hearth.scan import join_path
from std.ffi import external_call
from std.os import makedirs
from std.pathlib import Path


def _nul_terminated(s: String) -> List[UInt8]:
    var buf = List[UInt8]()
    for b in s.as_bytes():
        buf.append(b)
    buf.append(0)
    return buf^


def _rename(old_path: String, new_path: String) raises:
    var ob = _nul_terminated(old_path)
    var nb = _nul_terminated(new_path)
    var rc = external_call["rename", Int32](ob.unsafe_ptr(), nb.unsafe_ptr())
    if rc != 0:
        raise Error(
            "write: rename failed (" + old_path + " -> " + new_path + ")"
        )


def _remove_file(path: String):
    var pb = _nul_terminated(path)
    _ = external_call["unlink", Int32](pb.unsafe_ptr())


def _remove_dir(path: String):
    var pb = _nul_terminated(path)
    _ = external_call["rmdir", Int32](pb.unsafe_ptr())


def remove_tree(path: String) raises:
    var p = Path(path)
    if not p.exists():
        return
    if not p.is_dir():
        _remove_file(path)
        return
    for entry in p.listdir():
        var full = String(entry)
        # listdir entries may be full paths already; join only if needed.
        var child = full if full.startswith("/") or full.startswith(path) else join_path(path, full)
        remove_tree(child)
    _remove_dir(path)


def materialize(files: List[OutputFile], target_dir: String) raises:
    var tmp_dir = target_dir + ".hearth-tmp"
    var old_dir = target_dir + ".hearth-old"
    remove_tree(tmp_dir)
    remove_tree(old_dir)
    makedirs(tmp_dir, exist_ok=True)
    for ref f in files:
        var dest = join_path(tmp_dir, f.rel_path)
        # Create the parent chain: strip the final component.
        var slash = dest.rfind("/")
        if slash > 0:
            makedirs(String(dest[byte=:slash]), exist_ok=True)
        var handle = open(dest, "w")
        handle.write(f.content)
        handle.close()
    if Path(target_dir).exists():
        _rename(target_dir, old_dir)
        try:
            _rename(tmp_dir, target_dir)
        except e:
            _rename(old_dir, target_dir)
            raise e^
        remove_tree(old_dir)
    else:
        _rename(tmp_dir, target_dir)
