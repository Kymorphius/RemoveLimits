# Optional player-save buffer patch / 可选人物存档扩容补丁 / Необязательный патч сохранения

**Single-player Build 42.20.4 only. Manual installation. Most players do not need this.**

## 中文

无限重量不等于无限存档数据。人物身上、穿戴或手持的背包及其嵌套物品会一起写入人物存档；物品重量、减重率、背包数量都不能直接代表这些数据的大小。大量随身物品可能在 `PlayerDB.savePlayersAsync` 中触发 `BufferOverflowException`，导致此次人物保存失败，重进后回到上次成功保存的状态。

普通玩家通常不需要此补丁。它只针对已核对的 **Build 42.20.4 单机人物存档序列化**：

- 将缓冲区上限从 **2 MiB 提高到 64 MiB**，按需倍增，不预先分配 64 MiB；不改变物品内容和存档格式。
- **不是字面上的无限容量，也不能保证永不丢档**。大背包仍可能消耗大量内存、卡顿或碰到其他引擎限制；大缓冲区会被复用，保存队列和数据复制还会占用额外内存。
- 不支持多人、服务器或 Build 41；不修复磁盘已满、内存不足、其他模组的存档错误，也不能找回之前保存失败而丢失的物品。
- 订阅或启用本模组**不会自动安装**此补丁。它是独立工具，不是新的沙盒设置。
- 工具只包含我们自己的代码，不附带游戏文件。按游戏类的完整 SHA-256 校验版本；不匹配就拒绝修改，请勿强行绕过。

### 安装前

1. 完全退出游戏和服务器，并暂停 Steam 的游戏更新。运行中的游戏不会因为磁盘文件改变而安全地切换补丁。
2. **另行备份整个存档目录**：Windows 通常为 `%UserProfile%\Zomboid\Saves`，macOS/Linux 通常为 `~/Zomboid/Saves`；自定义缓存目录请备份实际位置。
3. 先在存档副本上验证。工具会备份游戏 JAR，但**游戏 JAR 备份不等于存档备份**。

### 找到文件并运行

本说明和 `SaveBufferPatch.jar` 位于订阅内容下：

```text
Steam/steamapps/workshop/content/108600/3546219719/mods/RemoveLimits/common/OptionalSavePatch/
```

在 Steam → Project Zomboid → 管理 → 浏览本地文件找到游戏目录。打开本补丁目录的终端，使用下方对应系统命令。示例路径必须替换为自己的路径；`check` 只检查、不修改。

**Windows（命令提示符 CMD）**：

```bat
"C:\...\ProjectZomboid\jre64\bin\java.exe" -jar "SaveBufferPatch.jar" check "C:\...\ProjectZomboid"
"C:\...\ProjectZomboid\jre64\bin\java.exe" -jar "SaveBufferPatch.jar" install "C:\...\ProjectZomboid"
```

**macOS（终端）**：

```sh
"/path/to/ProjectZomboid/Project Zomboid.app/Contents/PlugIns/jre-aarch64/Contents/Home/bin/java" -jar "SaveBufferPatch.jar" check "/path/to/ProjectZomboid"
"/path/to/ProjectZomboid/Project Zomboid.app/Contents/PlugIns/jre-aarch64/Contents/Home/bin/java" -jar "SaveBufferPatch.jar" install "/path/to/ProjectZomboid"
```

Intel Mac 将 `jre-aarch64` 换成 `jre-x86_64`。若对应运行时不存在，请使用游戏实际附带的 Java 路径。

**Linux（终端）**：

```sh
"/path/to/ProjectZomboid/jre64/bin/java" -jar "SaveBufferPatch.jar" check "/path/to/ProjectZomboid"
"/path/to/ProjectZomboid/jre64/bin/java" -jar "SaveBufferPatch.jar" install "/path/to/ProjectZomboid"
```

工具自身需要 Java 11 或更高版本，优先使用游戏自带 Java。也可直接将第二个参数指定为实际的 `projectzomboid.jar` 路径。若游戏安装布局、版本或类校验不匹配，停止并反馈，不要替换其他文件来凑路径。

显示 `Installed` 后再次运行 `check`，应显示 `PATCHED`。然后在**存档副本**中拾取、保存、退出、重进，核对物品及人物状态。我们已做隔离的字节码和安装/还原测试；这不等于所有平台、真实物品组合及模组组合都已实测。

### 还原、更新与错误

- 同一命令将 `install` 改成 `restore` 即可还原；依然要先退出游戏。
- 游戏 JAR 旁会保留 `projectzomboid.jar.removelimits-save-backup`。还原只接受匹配的备份，且确认其他 JAR 内容未被后来的补丁或更新改变；不会用旧备份覆盖新内容。
- Steam 更新或验证完整性可能移除此补丁。之后先运行 `check`；新版本不支持就等待适配。**不要直接覆盖游戏更新，不要删除备份来绕过拒绝提示。**
- 缺少备份可用 Steam 验证游戏文件恢复官方文件；这也可能移除其他 Java 补丁。
- **取消订阅模组不等于卸载原生补丁。** 需要手动还原或验证游戏文件。
- 人物数据已超过原版上限时，移除补丁后仍可能无法再次保存。建议先保持补丁有效，把大量随身物品移入世界容器，在存档副本中验证还原后的保存与重载；不能仅凭重量或件数判断是否已低于限制。
- `STOP` 表示操作失败或被拒绝。保留完整输出和备份，别连续强行安装。检测运行中游戏只能尽力而为，务必自行确认已退出。系统不提供 Java 进程参数时（例如 Windows），工具会保守拦截其他 Java 进程；先关闭相关 Java 应用再试。

## English

Unlimited weight does not mean unlimited save data. Carried, worn and held bags, including nested contents, are serialized with the player. Weight, weight reduction and item count do not reliably measure the serialized size. Very large inventories can cause `PlayerDB.savePlayersAsync` / `BufferOverflowException`: the player is not saved and reload may return to the last successful save.

This optional tool changes **only the verified single-player Build 42.20.4 serialization buffer**, from **2 MiB to 64 MiB**, growing by doubling on demand. It preserves item bytes and the save format. It is not literal infinity or a guarantee against data loss: retained buffers, queued snapshots and copying need memory, and other engine limits remain. It does not support multiplayer, servers or Build 41, repair unrelated mod/disk/memory errors, or recover items already lost. Most players do not need it. Subscribing/enabling the mod does **not** install it.

### Use

1. Close the game/server and pause game updates. **Back up your entire save separately** (`%UserProfile%\Zomboid\Saves` on Windows, `~/Zomboid/Saves` on macOS/Linux unless customized). The tool's JAR backup is **not a save backup**.
2. Find the optional patch in the Workshop path above; use Steam's Browse Local Files to find the game directory. Open a terminal in this optional-patch directory.
3. Use the platform commands shown above, replacing the example paths. Run `check` first, then `install`. The game's bundled Java is recommended; the tool requires Java 11+. On Intel Macs use `jre-x86_64` instead of `jre-aarch64`. An explicit path to `projectzomboid.jar` is also accepted.
4. `Installed`, then `check` reporting `PATCHED`, confirms the file patch. **On a copied save**, test collecting, saving, quitting, reloading and checking inventory/state. Isolated bytecode and install/restore tests are not full in-game or cross-platform validation.

The tool ships only our own code, verifies the entire target class with SHA-256, backs up the original JAR and replaces it atomically. Unknown versions are rejected. Do not bypass checks or improvise a different game-file layout. Process detection is best-effort: personally verify that the game is closed. If Java process arguments are unavailable (for example on Windows), other Java processes conservatively block installation; close those Java applications before retrying.

### Restore and updates

Replace `install` with `restore` in the same command. Keep the adjacent `projectzomboid.jar.removelimits-save-backup`; restoration refuses a mismatched backup or later changes to other JAR contents. Steam updates/integrity verification may remove the patch: re-run `check`, and wait for support if the version is unknown. Do not overwrite updates or delete backups to bypass refusal. If the backup is missing, Steam Verify Integrity can restore official files, but may remove other Java patches too. Unsubscribing from the mod does **not** uninstall this native patch.

An inventory already over the original limit may fail to save again after restoration. While still patched, move excess carried contents into world containers; test unpatched saving/reloading on a save copy before returning to normal play. Weight/count alone cannot prove that you are under the limit. `STOP` means failure/refusal: retain the output and backups rather than forcing repeated installs.

## Русский

Неограниченный вес не означает неограниченный размер сохранения. Содержимое переносимых, надетых и удерживаемых сумок, включая вложенные контейнеры, сохраняется вместе с персонажем. Вес, снижение веса и число предметов не позволяют точно определить размер данных. Очень большой инвентарь может вызвать `PlayerDB.savePlayersAsync` / `BufferOverflowException`: персонаж не сохраняется, а после загрузки возвращается последнее успешно сохранённое состояние.

Этот необязательный инструмент меняет **только проверенный буфер сериализации одиночной игры Build 42.20.4**: **2 МиБ → 64 МиБ**, с удвоением по необходимости, без предварительного выделения 64 МиБ. Данные предметов и формат сохранения не меняются. Это не буквальная бесконечность и не гарантия от потери данных: буферы, очередь сохранений и копирование требуют памяти, другие ограничения движка остаются. Мультиплеер, серверы и Build 41 не поддерживаются. Патч не исправляет ошибки других модов, нехватку памяти/места и не возвращает уже потерянные предметы. Большинству игроков он не нужен. Подписка и включение мода **не устанавливают** патч автоматически.

### Установка

1. Полностью закройте игру/сервер и приостановите обновления. **Отдельно скопируйте всю папку сохранений**: обычно `%UserProfile%\Zomboid\Saves` в Windows или `~/Zomboid/Saves` в macOS/Linux. При нестандартной папке кэша используйте её фактический путь. Резервная копия JAR **не является копией сохранения**.
2. Найдите патч по пути Workshop выше, а папку игры — через Steam → управление → просмотр локальных файлов. Откройте терминал в папке патча.
3. Используйте команды для вашей системы, приведённые выше, заменив примеры путей. Сначала `check` (без изменений), затем `install`. Рекомендуется Java из комплекта игры; инструменту нужна Java 11+. На Intel Mac замените `jre-aarch64` на `jre-x86_64`. Допускается указать полный путь к `projectzomboid.jar` вместо папки игры.
4. После `Installed` команда `check` должна показать `PATCHED`. **На копии сохранения** проверьте сбор предметов, сохранение, выход, повторную загрузку и состояние инвентаря/персонажа. Изолированные тесты байткода и установки/восстановления не заменяют проверку в игре на всех платформах и наборах модов.

В комплекте только наш код, без файлов игры. Полный SHA-256 класса проверяется до изменения; неизвестные версии отклоняются. Создаётся резервная копия JAR, замена атомарная. Не обходите проверки и не подставляйте другие файлы. Обнаружение работающей игры не абсолютно надёжно: убедитесь сами, что она закрыта. Если аргументы Java-процессов недоступны (например, в Windows), другие Java-процессы также блокируют установку в целях безопасности; закройте эти приложения перед повторной попыткой.

### Удаление и обновления

Замените `install` на `restore` в той же команде, предварительно закрыв игру. Сохраните соседний файл `projectzomboid.jar.removelimits-save-backup`. Восстановление запрещено при несовпадении копии или последующих изменениях других файлов внутри JAR. Обновления Steam и проверка целостности могут удалить патч: снова выполните `check`, а при неизвестной версии дождитесь адаптации. Не перезаписывайте обновления и не удаляйте копию ради обхода отказа. Если копия отсутствует, проверка целостности Steam восстановит официальные файлы, но может удалить другие Java-патчи. Отписка от мода **не удаляет** этот нативный патч.

Если данные персонажа уже превысили исходный предел, после удаления патча сохранение снова может не работать. Пока патч установлен, перенесите лишние вещи из инвентаря в контейнеры мира; проверьте сохранение/загрузку без патча на копии сохранения. По весу или числу предметов нельзя гарантировать соблюдение предела. `STOP` означает ошибку или отказ: сохраните вывод и резервную копию, не пытайтесь принудительно повторять установку.

## Developer verification

From the GitHub repository root (JDK 17+ for building):

```sh
sh tools/build-save-patch.sh
python3 tests/save_patch_installer_regression.py "/path/to/original/projectzomboid.jar"
python3 tests/native_save_patch_regression.py "/path/to/original/projectzomboid.jar" "/path/to/patched-copy/projectzomboid.jar" --java "/path/to/game/java"
lua tests/capacity_regression.lua
lua tests/mod_options_regression.lua
```

The native test uses Java 25 to verify the actual Build 42.20.4 class with isolated player fixtures, not a live game or real saves. No proprietary game class is distributed. Rebuilds use fixed archive timestamps.

Target: `zombie/savefile/PlayerDB$PlayerData.class` (4,055 bytes).

```text
Original SHA-256: baaad16f1fd10a185530cc4f692abaafc1fc8ce6b139299553a01efb9a6239af
Patched  SHA-256: 4cae6832c7d9f0f7b94eb0573e5964a0b34a907b926065a209b570b13bc5179c
```

Only four bytes change: integer constant #115 (2 MiB → 64 MiB) and `ldc #15` → `dup; nop` in the growth expression (capacity + 32768 → capacity + capacity). Initial allocation stays 32 KiB. Instruction lengths, branch offsets and stack-map frames remain unchanged. The finite 64 MiB ceiling is deliberate; supporting other builds or the multiplayer save path requires separate native verification, not disabling the hash guard.
