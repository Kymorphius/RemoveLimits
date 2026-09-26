#!/usr/bin/env python3
"""Exercise actual PlayerData bytecode with isolated, in-memory player fixtures.

Usage: python3 tests/native_save_patch_regression.py ORIGINAL.jar PATCHED.jar
Requires javac (17+) and Java 25; the installed game's bundled Java is preferred.
Only a TemporaryDirectory is written. No game classes other than PlayerData and
its JDK-only ByteBufferOutputStream dependency are loaded from either archive.
"""

import argparse
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import zipfile


SOURCES = {
    "zombie/savefile/PlayerDB.java": """
package zombie.savefile;
import java.nio.ByteBuffer;
public class PlayerDB {
    public static final ThreadLocal<ByteBuffer> TL_SliceBuffer =
        ThreadLocal.withInitial(() -> ByteBuffer.allocate(32768));
    public static final ThreadLocal<byte[]> TL_Bytes =
        ThreadLocal.withInitial(() -> new byte[1024]);
    // Supplies the original class's NestHost/NestMembers relationship.
    private static final class PlayerData {}
}
""",
    "zombie/characters/SurvivorDesc.java": """
package zombie.characters;
public class SurvivorDesc {
    public String getForename() { return "Test"; }
    public String getSurname() { return "Player"; }
}
""",
    "zombie/characters/IsoPlayer.java": """
package zombie.characters;
import java.nio.ByteBuffer;
public class IsoPlayer {
    public int sqlId = 1;
    public int calls;
    public final byte[] payload;
    public IsoPlayer(int size) {
        payload = new byte[size];
        java.util.Arrays.fill(payload, (byte) 0x5a);
        payload[0] = 0x12;
        payload[size - 1] = 0x34;
    }
    public float getX() { return 1; }
    public float getY() { return 2; }
    public float getZ() { return 0; }
    public boolean isDead() { return false; }
    public SurvivorDesc getDescriptor() { return new SurvivorDesc(); }
    public String getUsername() { return "isolated-regression"; }
    public void save(ByteBuffer buffer) { calls++; buffer.put(payload); }
}
""",
    "zombie/iso/IsoWorld.java": """
package zombie.iso;
public class IsoWorld {
    public static int getWorldVersion() { return 1; }
}
""",
    "zombie/debug/DebugType.java": """
package zombie.debug;
public class DebugType {
    public static final DebugType DetailedInfo = new DebugType();
    public void error(String format, Object... arguments) {}
}
""",
    "zombie/savefile/NativeSaveProbe.java": """
package zombie.savefile;
import java.io.ByteArrayInputStream;
import java.lang.reflect.*;
import java.nio.*;
import java.security.MessageDigest;
import java.util.*;
import zombie.characters.IsoPlayer;

public class NativeSaveProbe {
    static Class<?> type;
    static Constructor<?> constructor;
    static Method save;
    static Method loadBytes;
    static Field bytes;
    static final int MIB = 1024 * 1024;

    static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    static Object emptyData() throws Exception {
        return constructor.newInstance();
    }
    static void invokeSave(Object data, IsoPlayer player, boolean overflow)
            throws Exception {
        try {
            save.invoke(data, player);
            check(!overflow, "expected BufferOverflowException");
        } catch (InvocationTargetException ex) {
            if (!overflow || !(ex.getCause() instanceof BufferOverflowException))
                throw ex;
        }
    }
    static byte[] savedBytes(Object data) throws Exception {
        ByteBuffer buffer = ((ByteBuffer) bytes.get(data)).duplicate();
        byte[] result = new byte[buffer.remaining()];
        buffer.get(result);
        return result;
    }
    static void equalPayload(Object data, byte[] expected) throws Exception {
        check(Arrays.equals(expected, savedBytes(data)), "payload changed");
    }
    static void smallPayload() throws Exception {
        IsoPlayer player = new IsoPlayer(4096);
        Object data = emptyData();
        invokeSave(data, player, false);
        equalPayload(data, player.payload);
        check(player.calls == 1, "small payload retried");
        System.out.println("small_sha256=" + HexFormat.of().formatHex(
            MessageDigest.getInstance("SHA-256").digest(savedBytes(data))));
    }
    static void largerThanOriginal(boolean patched) throws Exception {
        PlayerDB.TL_SliceBuffer.remove();
        IsoPlayer player = new IsoPlayer(2 * MIB + 17);
        Object data = emptyData();
        invokeSave(data, player, !patched);
        if (patched) {
            equalPayload(data, player.payload);
            check(player.calls == 8, "expected doubling to 4 MiB in 8 attempts");
            ByteBuffer retained = PlayerDB.TL_SliceBuffer.get();
            check(retained.capacity() == 4 * MIB, "wrong enlarged capacity");
            player.calls = 0;
            invokeSave(data, player, false);
            equalPayload(data, player.payload);
            check(player.calls == 1, "buffer was not reused");
            check(PlayerDB.TL_SliceBuffer.get() == retained, "buffer replaced");
        } else {
            check(player.calls == 64, "expected original 32 KiB linear growth");
            check(PlayerDB.TL_SliceBuffer.get().capacity() == 2 * MIB,
                "original limit changed");
        }
    }
    static void rejectsAboveCap() throws Exception {
        PlayerDB.TL_SliceBuffer.remove();
        IsoPlayer player = new IsoPlayer(64 * MIB + 1);
        invokeSave(emptyData(), player, true);
        check(player.calls == 12, "expected 12 attempts to reach 64 MiB");
        check(PlayerDB.TL_SliceBuffer.get().capacity() == 64 * MIB,
            "grew beyond 64 MiB");
        PlayerDB.TL_SliceBuffer.remove();
    }
    static void largeLoad() throws Exception {
        IsoPlayer player = new IsoPlayer(3 * MIB + 29);
        Object data = emptyData();
        loadBytes.invoke(data, new ByteArrayInputStream(player.payload));
        equalPayload(data, player.payload);
    }
    public static void main(String[] arguments) throws Exception {
        boolean patched = arguments[0].equals("patched");
        type = Class.forName("zombie.savefile.PlayerDB$PlayerData");
        constructor = type.getDeclaredConstructor();
        constructor.setAccessible(true);
        save = type.getDeclaredMethod("set", IsoPlayer.class);
        save.setAccessible(true);
        loadBytes = type.getDeclaredMethod("setBytes", java.io.InputStream.class);
        loadBytes.setAccessible(true);
        bytes = type.getDeclaredField("byteBuffer");
        bytes.setAccessible(true);
        smallPayload();
        largerThanOriginal(patched);
        if (patched) rejectsAboveCap();
        largeLoad();
        System.out.println(arguments[0] + ": PASS");
    }
}
""",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    parser.add_argument("patched", type=Path)
    parser.add_argument("--java", help="Java 25 executable")
    parser.add_argument("--javac", default=shutil.which("javac"))
    args = parser.parse_args()
    arch = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
    bundled = args.original.resolve().parent.parent / (
        f"PlugIns/jre-{arch}/Contents/Home/bin/java"
    )
    java = args.java or (str(bundled) if bundled.is_file() else shutil.which("java"))
    if not java or not args.javac:
        parser.error("Java 25 and javac are required; use --java and --javac")

    with tempfile.TemporaryDirectory(prefix="remove-limits-native-test-") as tmp:
        root = Path(tmp)
        source_paths = []
        for relative, source in SOURCES.items():
            path = root / "src" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
            source_paths.append(str(path))
        fixtures = root / "fixtures"
        fixtures.mkdir()
        subprocess.run([args.javac, "--release", "17", "-d", str(fixtures),
                        *source_paths], check=True)
        small_digests = []
        for label, archive in (("original", args.original), ("patched", args.patched)):
            classes = root / label
            shutil.copytree(fixtures, classes)
            with zipfile.ZipFile(archive) as jar:
                for name in ("zombie/savefile/PlayerDB$PlayerData.class",
                             "zombie/util/ByteBufferOutputStream.class"):
                    destination = classes / name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(jar.read(name))
            result = subprocess.run(
                [java, "-Xverify:all", "-Xmx384m", "-ea", "-cp", str(classes),
                 "zombie.savefile.NativeSaveProbe", label],
                check=True, text=True, stdout=subprocess.PIPE,
            )
            print(result.stdout, end="")
            small_digests.append(next(line for line in result.stdout.splitlines()
                                      if line.startswith("small_sha256=")))
        if small_digests[0] != small_digests[1]:
            raise AssertionError("original/patched small payload bytes differ")
    print("PASS: actual bytecode verified; limits, growth, reuse and stream loading checked")


if __name__ == "__main__":
    main()
