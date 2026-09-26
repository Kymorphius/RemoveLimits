import java.io.IOException;
import java.io.InputStream;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.stream.Stream;
import java.util.zip.*;

/** Optional, manual, single-player Build 42.20.4 patch. Contains no game code. */
public final class SaveBufferPatch {
    static final String ENTRY = "zombie/savefile/PlayerDB$PlayerData.class";
    static final String ORIGINAL = "baaad16f1fd10a185530cc4f692abaafc1fc8ce6b139299553a01efb9a6239af";
    static final String PATCHED = "4cae6832c7d9f0f7b94eb0573e5964a0b34a907b926065a209b570b13bc5179c";
    static final String BACKUP_SUFFIX = ".removelimits-save-backup";

    public static void main(String[] args) {
        try {
            if (args.length != 2 || !Set.of("check", "install", "restore").contains(args[0])) {
                throw new IOException("Usage: java -jar SaveBufferPatch.jar check|install|restore \"game folder or projectzomboid.jar\"");
            }
            Path game = locate(Paths.get(args[1]));
            Path backup = game.resolveSibling(game.getFileName() + BACKUP_SUFFIX);
            String state = sha(classBytes(game));
            System.out.println("Target: " + game);
            if (!ORIGINAL.equals(state) && !PATCHED.equals(state)) {
                throw new IOException("Unsupported PlayerData class. Expected Build 42.20.4; no files changed. SHA-256: " + state);
            }
            if (args[0].equals("check")) {
                System.out.println(ORIGINAL.equals(state) ? "SUPPORTED: original 2 MiB limit." : "PATCHED: 64 MiB limit, doubling growth.");
                System.out.println("Single-player only. Back up your SAVE separately; this tool only backs up the game JAR.");
                if (Files.exists(backup)) System.out.println("JAR backup: " + backup);
                return;
            }
            ensureGameStopped();
            if (args[0].equals("install")) {
                if (PATCHED.equals(state)) {
                    System.out.println("Already patched; nothing changed.");
                    return;
                }
                install(game, backup);
                System.out.println("Installed: 2 MiB -> 64 MiB, allocated on demand. Backup: " + backup);
            } else {
                if (ORIGINAL.equals(state)) {
                    System.out.println("Already original; nothing changed.");
                    return;
                }
                restore(game, backup);
                System.out.println("Restored the exact original JAR. Backup retained: " + backup);
            }
        } catch (Exception error) {
            System.err.println("STOP: " + error.getMessage());
            System.err.println("Do not force a version mismatch or delete backups to bypass a check. See README.md.");
            System.exit(1);
        }
    }

    static Path locate(Path path) throws IOException {
        if (Files.isDirectory(path)) {
            List<Path> found = new ArrayList<>();
            for (String relative : List.of("projectzomboid.jar", "Project Zomboid.app/Contents/Java/projectzomboid.jar", "Contents/Java/projectzomboid.jar")) {
                Path candidate = path.resolve(relative);
                if (Files.isRegularFile(candidate)) found.add(candidate);
            }
            if (found.size() != 1) throw new IOException("Select the game folder containing projectzomboid.jar (exactly one match required).");
            path = found.get(0);
        }
        if (!Files.isRegularFile(path) || !path.getFileName().toString().equals("projectzomboid.jar")) {
            throw new IOException("Not a projectzomboid.jar file: " + path);
        }
        return path.toRealPath();
    }

    static void ensureGameStopped() throws IOException {
        try (Stream<ProcessHandle> processes = ProcessHandle.allProcesses()) {
            boolean running = processes.filter(p -> p.pid() != ProcessHandle.current().pid()).anyMatch(p -> {
                ProcessHandle.Info info = p.info();
                return blocksPatching(info.command().orElse("unknown"), info.arguments().orElse(new String[0]));
            });
            if (running) throw new IOException("Close Project Zomboid/server before installing/restoring. Also close unidentified Java apps when their process arguments cannot be inspected.");
        }
    }

    static boolean blocksPatching(String command, String[] args) {
        command = command.replace('\\', '/').toLowerCase(Locale.ROOT);
        String name = command.substring(command.lastIndexOf('/') + 1);
        // Windows may expose only the executable, not arguments: fail closed for other Java processes.
        boolean java = Set.of("java", "java.exe", "javaw", "javaw.exe").contains(name);
        return name.contains("projectzomboid") || name.contains("project zomboid")
                || (name.equals("javaapplauncher") && command.contains("project zomboid.app"))
                || (java && args.length == 0)
                || Arrays.stream(args).anyMatch(a -> a.equals("zombie.gameStates.MainScreenState")
                || a.equals("zombie.GameWindow") || a.equals("zombie.network.GameServer"));
    }

    static byte[] classBytes(Path jar) throws IOException {
        try (ZipFile zip = new ZipFile(jar.toFile())) {
            ZipEntry entry = zip.getEntry(ENTRY);
            if (entry == null) throw new IOException("PlayerData class not found in " + jar);
            try (InputStream in = zip.getInputStream(entry)) { return in.readAllBytes(); }
        }
    }

    static byte[] patch(byte[] bytes) throws Exception {
        if (!ORIGINAL.equals(sha(bytes))) throw new IOException("Unsupported PlayerData class; refused to patch.");
        byte[] result = bytes.clone();
        // Exact-class hash pins these offsets to Build 42.20.4. No code offsets or frames move.
        // CONSTANT_Integer #115: 2 MiB -> 64 MiB.
        result[1175] = 4;
        result[1176] = 0;
        // capacity + 32768 -> capacity + capacity: ldc #15 -> dup; nop.
        result[3073] = 0x59;
        result[3074] = 0;
        if (!PATCHED.equals(sha(result))) throw new IOException("Internal patch verification failed.");
        return result;
    }

    static String sha(byte[] bytes) throws Exception {
        return hex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    static String fileSha(Path file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream in = Files.newInputStream(file)) {
            byte[] buffer = new byte[65536];
            int count;
            while ((count = in.read(buffer)) != -1) digest.update(buffer, 0, count);
        }
        return hex(digest.digest());
    }

    static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder();
        for (byte value : bytes) text.append(String.format("%02x", value & 255));
        return text.toString();
    }

    static void install(Path game, Path backup) throws Exception {
        String before = fileSha(game);
        byte[] replacement = patch(classBytes(game));
        if (Files.exists(backup, LinkOption.NOFOLLOW_LINKS)) {
            if (Files.isSymbolicLink(backup) || !before.equals(fileSha(backup))) {
                throw new IOException("Existing backup differs. Preserve it; resolve the game update/other patch before continuing.");
            }
        } else {
            // Never overwrite a prior backup. A failed/incomplete backup blocks installation.
            Files.copy(game, backup, StandardCopyOption.COPY_ATTRIBUTES);
        }
        if (!before.equals(fileSha(backup))) throw new IOException("Backup verification failed; original JAR left in place.");
        Path temp = Files.createTempFile(game.getParent(), ".removelimits-save-", ".tmp");
        try {
            rewrite(game, temp, replacement);
            verifyPair(backup, temp);
            replaceChecked(game, temp, before);
        } finally {
            Files.deleteIfExists(temp);
        }
    }

    static void rewrite(Path original, Path output, byte[] replacement) throws IOException {
        try (ZipFile input = new ZipFile(original.toFile());
             ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(output))) {
            out.setComment(input.getComment());
            Enumeration<? extends ZipEntry> entries = input.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                String name = entry.getName();
                String upper = name.toUpperCase(Locale.ROOT);
                if (upper.startsWith("META-INF/") && (upper.endsWith(".SF") || upper.endsWith(".RSA") || upper.endsWith(".DSA") || upper.endsWith(".EC"))) {
                    throw new IOException("Signed JAR unsupported; original JAR left in place.");
                }
                ZipEntry copy = new ZipEntry(entry);
                // Compressed sizes are recomputed; STORED sizes/CRC must match the new bytes.
                if (copy.getMethod() == ZipEntry.DEFLATED) copy.setCompressedSize(-1);
                if (name.equals(ENTRY)) {
                    CRC32 crc = new CRC32();
                    crc.update(replacement);
                    copy.setSize(replacement.length);
                    copy.setCrc(crc.getValue());
                    if (copy.getMethod() == ZipEntry.STORED) copy.setCompressedSize(replacement.length);
                }
                out.putNextEntry(copy);
                if (name.equals(ENTRY)) out.write(replacement);
                else try (InputStream in = input.getInputStream(entry)) { in.transferTo(out); }
                out.closeEntry();
            }
        }
        copyPermissions(original, output);
    }

    static void verifyPair(Path original, Path patched) throws Exception {
        if (Files.isSymbolicLink(original) || !ORIGINAL.equals(sha(classBytes(original))) || !PATCHED.equals(sha(classBytes(patched)))) {
            throw new IOException("Backup/patch verification failed; no replacement performed.");
        }
        // Compare all other entries: restoration must not discard later Java mods or updates.
        try (ZipFile left = new ZipFile(original.toFile()); ZipFile right = new ZipFile(patched.toFile())) {
            if (left.size() != right.size()) throw new IOException("JAR entries differ from the backup; refusing restoration/replacement.");
            Set<String> names = new HashSet<>();
            Enumeration<? extends ZipEntry> entries = left.entries();
            while (entries.hasMoreElements()) {
                ZipEntry a = entries.nextElement();
                ZipEntry b = right.getEntry(a.getName());
                if (!names.add(a.getName()) || b == null) throw new IOException("Duplicate/missing JAR entry: " + a.getName());
                if (a.getName().equals(ENTRY)) continue;
                try (InputStream x = left.getInputStream(a); InputStream y = right.getInputStream(b)) {
                    while (true) {
                        byte[] xb = x.readNBytes(65536);
                        byte[] yb = y.readNBytes(65536);
                        if (!Arrays.equals(xb, yb)) throw new IOException("Another JAR entry changed: " + a.getName() + "; refusing to overwrite it.");
                        if (xb.length == 0) break;
                    }
                }
            }
        }
    }

    static void restore(Path game, Path backup) throws Exception {
        if (!Files.isRegularFile(backup)) throw new IOException("Original JAR backup is missing. Use Steam Verify Integrity, then re-check before playing.");
        String before = fileSha(game);
        verifyPair(backup, game);
        String backupHash = fileSha(backup);
        Path temp = Files.createTempFile(game.getParent(), ".removelimits-restore-", ".tmp");
        try {
            Files.copy(backup, temp, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.COPY_ATTRIBUTES);
            if (!backupHash.equals(fileSha(temp))) throw new IOException("Restore copy verification failed.");
            replaceChecked(game, temp, before);
        } finally {
            Files.deleteIfExists(temp);
        }
    }

    static void copyPermissions(Path from, Path to) throws IOException {
        if (Files.getFileStore(from).supportsFileAttributeView("posix")) {
            Files.setPosixFilePermissions(to, Files.getPosixFilePermissions(from));
        }
    }

    static void replaceChecked(Path game, Path temp, String before) throws Exception {
        ensureGameStopped();
        if (!before.equals(fileSha(game))) throw new IOException("Game JAR changed during this operation; refusing to replace it.");
        // No delete/copy fallback: on filesystems without atomic replacement, fail safely.
        Files.move(temp, game, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    }
}
