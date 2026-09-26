#!/usr/bin/env python3
"""Exercise the optional installer against temporary copies, never the game JAR."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


ENTRY = "zombie/savefile/PlayerDB$PlayerData.class"
ORIGINAL_CLASS = "baaad16f1fd10a185530cc4f692abaafc1fc8ce6b139299553a01efb9a6239af"
PATCHED_CLASS = "4cae6832c7d9f0f7b94eb0573e5964a0b34a907b926065a209b570b13bc5179c"
BACKUP_SUFFIX = ".removelimits-save-backup"


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def class_hash(path):
    with zipfile.ZipFile(path) as archive:
        return hashlib.sha256(archive.read(ENTRY)).hexdigest()


def snapshot(directory):
    return {str(path.relative_to(directory)): file_hash(path)
            for path in directory.rglob("*") if path.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path, help="Original Build 42.20.4 projectzomboid.jar (read-only)")
    parser.add_argument("--java", default="java", help="Java executable")
    parser.add_argument("--javac", default="javac", help="JDK 17+ compiler for the process-guard probe")
    args = parser.parse_args()
    patch = Path(__file__).resolve().parents[1] / "Contents/mods/RemoveLimits/common/OptionalSavePatch/SaveBufferPatch.jar"
    original = args.original.resolve()
    assert patch.is_file(), "Build SaveBufferPatch.jar first."
    assert class_hash(original) == ORIGINAL_CLASS, "This regression requires the original Build 42.20.4 class."
    original_hash = file_hash(original)

    def run(action, target, expected, succeeds=True):
        result = subprocess.run(
            [args.java, "-jar", str(patch), action, str(target)],
            capture_output=True, text=True, timeout=60,
        )
        output = result.stdout + result.stderr
        assert (result.returncode == 0) == succeeds, output
        assert expected in output, output

    with tempfile.TemporaryDirectory(prefix="removelimits-installer-test-") as temp:
        root = Path(temp)
        probe = root / "ProcessPredicateProbe.java"
        probe.write_text(r'''
public class ProcessPredicateProbe {
    static void expect(boolean blocked, String command, String... args) {
        if (SaveBufferPatch.blocksPatching(command, args) != blocked)
            throw new AssertionError(command + " " + java.util.Arrays.toString(args));
    }
    public static void main(String[] args) {
        for (String executable : new String[]{"java", "java.exe", "javaw", "javaw.exe"})
            expect(true, "C:\\Games\\ProjectZomboid\\jre64\\bin\\" + executable);
        expect(true, "C:\\Games\\ProjectZomboid\\ProjectZomboid64.exe");
        expect(true, "/games/Project Zomboid.app/Contents/MacOS/JavaAppLauncher");
        for (String main : new String[]{"zombie.GameWindow", "zombie.network.GameServer", "zombie.gameStates.MainScreenState"})
            expect(true, "/runtime/bin/java", "-cp", "game.jar", main);
        expect(false, "/runtime/bin/java", "-jar", "ordinary-service.jar");
        expect(false, "C:\\runtime\\javaw.exe", "-jar", "ordinary-service.jar");
        expect(false, "/usr/bin/python3");
        expect(false, "/Applications/Other.app/Contents/MacOS/JavaAppLauncher");
        System.out.println("process guard predicates: PASS");
    }
}
''', encoding="utf-8")
        server = root / "GameServer.java"
        server.write_text('''
package zombie.network;
public class GameServer {
    public static void main(String[] args) throws Exception {
        System.out.println("READY");
        System.out.flush();
        System.in.read();
    }
}
''', encoding="utf-8")
        subprocess.run([args.javac, "--release", "17", "-cp", str(patch), "-d", str(root),
                        str(probe), str(server)], check=True, timeout=60)
        subprocess.run([args.java, "-cp", os.pathsep.join((str(root), str(patch))),
                        "ProcessPredicateProbe"], check=True, timeout=30)

        with zipfile.ZipFile(original) as archive:
            original_class = archive.read(ENTRY)
        flat = root / "游戏平台 with spaces Ω" / "projectzomboid.jar"
        mac = root / "Mac 路径 with spaces" / "Project Zomboid.app" / "Contents" / "Java" / "projectzomboid.jar"
        for jar in (flat, mac):
            jar.parent.mkdir(parents=True)
            with zipfile.ZipFile(jar, "w") as archive:
                archive.writestr(ENTRY, original_class)
        before = snapshot(root)
        for location in (flat, flat.parent, mac, mac.parents[2], mac.parents[3]):
            run("check", location, "SUPPORTED: original 2 MiB limit.")
        assert snapshot(root) == before, "locator check changed files"
        ambiguous = flat.parent / "Project Zomboid.app" / "Contents" / "Java" / "projectzomboid.jar"
        ambiguous.parent.mkdir(parents=True)
        shutil.copy2(flat, ambiguous)
        before = snapshot(flat.parent)
        run("check", flat.parent, "exactly one match required", succeeds=False)
        assert snapshot(flat.parent) == before, "ambiguous locator refusal changed files"
        print("root/macOS-layout, Unicode/spaced paths, explicit JAR, ambiguous-folder checks: PASS")

        def copy_case(name, source):
            folder = root / name
            folder.mkdir()
            target = folder / "projectzomboid.jar"
            shutil.copy2(source, target)
            return target, target.with_name(target.name + BACKUP_SUFFIX)

        target, backup = copy_case("roundtrip", original)
        before = snapshot(target.parent)
        run("check", target.parent, "SUPPORTED: original 2 MiB limit.")
        assert snapshot(target.parent) == before, "check changed files"

        # A disposable blocking process exercises real enumeration, without starting the game.
        process = subprocess.Popen([args.java, "-cp", str(root), "zombie.network.GameServer"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert process.stdout.readline().strip() == "READY", "process-guard fixture did not start"
            for action in ("install", "restore"):
                run(action, target, "Close Project Zomboid/server", succeeds=False)
                assert snapshot(target.parent) == before, "running-game refusal changed files"
        finally:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=5)
        print("running-server install/restore refusals without mutation: PASS")

        run("install", target, "Installed: 2 MiB -> 64 MiB")
        assert file_hash(backup) == original_hash, "backup is not byte-for-byte original"
        assert class_hash(target) == PATCHED_CLASS, "wrong patched class"
        with zipfile.ZipFile(original) as left, zipfile.ZipFile(target) as right:
            assert left.namelist() == right.namelist(), "JAR entries changed"
            assert len(set(right.namelist())) == len(right.namelist()), "duplicate entries"
            for name in left.namelist():
                if name != ENTRY:
                    assert left.read(name) == right.read(name), f"unrelated entry changed: {name}"
        installed = snapshot(target.parent)
        assert set(installed) == {target.name, backup.name}, "temporary files leaked"
        run("check", target, "PATCHED: 64 MiB limit")
        run("install", target, "Already patched; nothing changed.")
        assert snapshot(target.parent) == installed, "check/repeated install changed files"
        print("check, patch hash, all other entries, exact backup, repeated install: PASS")

        missing, missing_backup = copy_case("missing-backup", target)
        before = snapshot(missing.parent)
        run("restore", missing, "Original JAR backup is missing", succeeds=False)
        assert not missing_backup.exists()
        assert snapshot(missing.parent) == before, "missing-backup refusal changed files"

        changed, changed_backup = copy_case("later-java-mod", target)
        shutil.copy2(backup, changed_backup)
        replacement = changed.with_suffix(".tmp")
        with zipfile.ZipFile(changed) as source, zipfile.ZipFile(replacement, "w") as output:
            other = next(info.filename for info in source.infolist() if not info.is_dir() and info.filename != ENTRY)
            for info in source.infolist():
                data = source.read(info.filename)
                if info.filename == other:
                    data += b"\ninstaller regression: another Java mod changed this entry\n"
                output.writestr(info, data)
        replacement.replace(changed)
        before = snapshot(changed.parent)
        run("restore", changed, "Another JAR entry changed:", succeeds=False)
        assert snapshot(changed.parent) == before, "restore discarded another Java mod"
        print("missing backup and changed unrelated-entry restoration refusals: PASS")

        run("restore", target, "Restored the exact original JAR.")
        assert file_hash(target) == original_hash, "restore is not byte-for-byte original"
        restored = snapshot(target.parent)
        assert restored[backup.name] == original_hash, "restore changed the retained backup"
        run("restore", target, "Already original; nothing changed.")
        assert snapshot(target.parent) == restored, "repeated restore changed files"
        print("exact restore and repeated restore: PASS")

        mismatched, mismatched_backup = copy_case("mismatched-backup", original)
        mismatched_backup.write_bytes(b"A previous backup must not be overwritten.")
        before = snapshot(mismatched.parent)
        run("install", mismatched, "Existing backup differs.", succeeds=False)
        assert snapshot(mismatched.parent) == before, "mismatched backup refusal changed files"

        unsupported = root / "unsupported"
        unsupported.mkdir()
        unknown = unsupported / "projectzomboid.jar"
        with zipfile.ZipFile(unknown, "w") as archive:
            archive.writestr(ENTRY, b"unknown future PlayerData version")
            archive.writestr("untouched.txt", b"must not change")
        before = snapshot(unsupported)
        for action in ("check", "install", "restore"):
            run(action, unknown, "Unsupported PlayerData class.", succeeds=False)
            assert snapshot(unsupported) == before, "unsupported class refusal changed files or created a backup"
        print("mismatched backup and unsupported class refusals: PASS")

    assert file_hash(original) == original_hash, "the supplied source JAR changed"
    print("optional save patch installer regression: PASS (source game JAR untouched)")


if __name__ == "__main__":
    main()
