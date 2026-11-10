//! Every user-visible string (Strings.cs, class S). Ukrainian when the user's UI language is Ukrainian,
//! English otherwise. Call `init()` once at startup; tests may set `uk` directly.
//! Members keep the C# names in Zig style: S.NewArchive -> `S.newArchive.get()` (keywords: @"error", @"test",
//! @"type", @"packed"). *Fmt members are .NET templates ("{0}", "{1}"): fill them with `fill` / `fillZ`.
//! ponytail: two hardcoded languages instead of resource tables; add a table per language if a third one shows up.
const std = @import("std");

/// CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "uk".
pub var uk: bool = false;
/// The user's number format ("#,0", "0.#"): set by init() from the current culture, as .NET formatting did.
pub var group_sep: []const u8 = ",";
pub var decimal_sep: []const u8 = ".";

extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;
extern "kernel32" fn GetLocaleInfoEx(name: ?[*:0]const u16, lctype: u32, data: ?[*]u16, cch: c_int) callconv(.winapi) c_int;

var sep_buf: [2][16]u8 = undefined;

pub fn init() void {
    uk = GetUserDefaultUILanguage() & 0x3FF == 0x22; // PRIMARYLANGID == LANG_UKRAINIAN
    if (localeText(0x0F, &sep_buf[0])) |s| group_sep = s; // LOCALE_STHOUSAND
    if (localeText(0x0E, &sep_buf[1])) |s| decimal_sep = s; // LOCALE_SDECIMAL
}

fn localeText(lctype: u32, out: *[16]u8) ?[]const u8 {
    var w: [4]u16 = undefined; // separators are at most 3 chars + NUL
    const n = GetLocaleInfoEx(null, lctype, &w, w.len); // null = LOCALE_NAME_USER_DEFAULT
    if (n <= 1) return null;
    return out[0..std.unicode.wtf16LeToWtf8(out, w[0..@intCast(n - 1)])];
}

/// One string in both languages; `get()` picks the current one (NUL-terminated for ImGui).
pub const Str = struct {
    u: [:0]const u8,
    e: [:0]const u8,
    pub fn get(s: Str) [:0]const u8 {
        return if (uk) s.u else s.e;
    }
};

/// C# `Uk ? "..." : "..."`: Ukrainian first, as in Strings.cs.
fn L(u: [:0]const u8, e: [:0]const u8) Str {
    return .{ .u = u, .e = e };
}

pub const app = "MakePack";

// toolbar / commands
pub const open = L("Відкрити…", "Open…");
pub const newArchive = L("Новий архів…", "New archive…");
pub const extract = L("Розпакувати…", "Extract…");
pub const @"test" = L("Перевірити", "Test");
pub const info = L("Відомості", "Info");
pub const delete = L("Вилучити", "Delete");
pub const addToArchive = L("Додати…", "Add…");
pub const addFilesToArchive = L("Додати файли…", "Add files…");
pub const assoc = L("Асоціації…", "Associations…");
pub const settingsMenu = L("Налаштування…", "Settings…");
pub const up = L("Вгору", "Up");
pub const browse = L("Огляд…", "Browse…");
pub const ok = L("Гаразд", "OK");
pub const cancel = L("Скасувати", "Cancel");
pub const create = L("Створити", "Create");
pub const remove = L("Вилучити", "Remove");
pub const addFiles = L("+ Файли…", "+ Files…");
pub const addFolder = L("+ Тека…", "+ Folder…");

// list columns
pub const name = L("Назва", "Name");
pub const size = L("Розмір", "Size");
pub const modified = L("Змінено", "Modified");
pub const @"type" = L("Тип", "Type");
pub const crc = L("CRC", "CRC");
pub const folderType = L("<тека>", "<folder>");

// status bar
pub const itemsFmt = L("{0} об'єктів", "{0} items");
pub const selectedFmt = L("{0} вибрано, {1}", "{0} selected, {1}");
pub const addedFmt = L("Додано: {0}", "Added: {0}");
pub const renamedFmt = L("Перейменовано: {0}", "Renamed: {0}");
pub const deletedFmt = L("Вилучено: {0}", "Deleted: {0}");

// dialogs
pub const password = L("Пароль", "Password");
pub const enterPassword = L("Архів зашифровано. Введіть пароль:", "The archive is encrypted. Enter the password:");
pub const destination = L("Тека призначення:", "Destination folder:");
pub const subFolderFmt = L("Розпакувати в підтеку «{0}»", "Extract into subfolder '{0}'");
pub const paths = L("Шляхи:", "Paths:");
pub const withPaths = L("Зберігати теки", "Keep folders");
pub const noPaths = L("Без тек (усе в одну)", "No folders (all in one)");
pub const update = L("Оновлення:", "Update:");
pub const updateReplace = L("Розпакувати все", "Extract all");
pub const updateNewer = L("Нові й новіші", "New and newer");
pub const updateExisting = L("Лише наявні, новіші", "Existing, if newer");
pub const updateTip = L(
    "«Нові й новіші» не чіпає файли, новіші за копію в архіві. «Лише наявні» оновлює тільки ті файли, що вже є в теці.",
    "\"New and newer\" leaves files that are newer than the archived copy. \"Existing\" only refreshes files already in the folder.",
);
pub const keepBroken = L("Залишати пошкоджені файли", "Keep broken files");
pub const archiveAfter = L("Архів:", "Archive:");
pub const deleteNever = L("Залишити", "Keep it");
pub const deleteAsk = L("Запитати, чи вилучити", "Ask to delete");
pub const deleteRecycle = L("Перемістити в Кошик", "Move to Recycle Bin");
pub const deleteAfterTip = L(
    "Лише коли розпаковано весь архів і без помилок. Для багатотомного — усі частини.",
    "Only when the whole archive was extracted without errors. For a multi-volume set, every part.",
);
pub const deleteArchiveAskFmt = L("Усе розпаковано. Перемістити «{0}» у Кошик?", "Everything was extracted. Move '{0}' to the Recycle Bin?");
pub const ifExists = L("Якщо файл існує:", "If a file exists:");
pub const ask = L("Запитати", "Ask");
pub const overwrite = L("Перезаписати", "Overwrite");
pub const skip = L("Пропустити", "Skip");
pub const rename = L("Перейменувати", "Rename");
pub const inputs = L("Файли й теки:", "Files and folders:");
pub const outputFile = L("Архів:", "Archive:");
pub const format = L("Формат:", "Format:");
pub const level = L("Рівень:", "Level:");
pub const encryptNames = L("Шифрувати імена файлів", "Encrypt file names");
pub const volumes = L("Томи:", "Volumes:");
pub const volumesHint = L("порожньо — один файл", "empty - a single file");
pub const badVolumeSize = L(
    "Розмір тому: число з одиницями, напр. 100 MB, 1,5 GB або 650m. Щонайменше 64 KB.",
    "Volume size: a number with a unit, e.g. 100 MB, 1.5 GB or 650m. At least 64 KB.",
);
pub const profile = L("Профіль:", "Profile:");
pub const saveProfile = L("Зберегти…", "Save…");
pub const saveProfileTitle = L("Зберегти профіль", "Save profile");
pub const renameProfile = L("Перейменувати профіль", "Rename profile");
pub const profileName = L("Назва профілю:", "Profile name:");
pub const defaultProfile = L("Типовий: підставляти щоразу, коли відкривається «Новий архів»", "Default: apply whenever New archive opens");
pub const noProfile = L("(без профілю)", "(no profile)");
pub const profileInMenu = L("Показувати в меню Провідника (без діалогу)", "Show in Explorer's menu (no dialog)");
pub const profileInMenuButton = L("У меню", "In menu");
pub const menuMark = L(" [у меню]", " [in menu]");
pub const menuProfiles = L("Профілі, позначені «у меню»", "Profiles marked \"in menu\"");
pub const verbProfileFmt = L("Додати в {0} — «{1}» (MakePack)", "Add to {0} - \"{1}\" (MakePack)");
pub const verbProfileSeparateFmt = L("Кожен в окремий {0} — «{1}» (MakePack)", "Each to its own {0} - \"{1}\" (MakePack)");
pub const defaultMark = L(" (типовий)", " (default)");
pub const profileExistsFmt = L("Профіль «{0}» уже є. Замінити його?", "A profile named '{0}' already exists. Replace it?");
pub const profileNameTakenFmt = L("Профіль «{0}» уже є. Оберіть іншу назву.", "A profile named '{0}' already exists. Choose another name.");
pub const profileNotFoundFmt = L("Профілю «{0}» немає. Створіть його в діалозі «Новий архів».", "There is no profile named '{0}'. Create it in the New archive dialog.");
pub const profiles = L("Профілі стиснення:", "Compression profiles:");
pub const renameButton = L("Перейменувати…", "Rename…");
pub const makeDefault = L("Типовий", "Default");
pub const confirm = L("Повтор:", "Confirm:");
pub const showPassword = L("Показати пароль", "Show password");
pub const passwordsDiffer = L("Паролі не збігаються. Введіть пароль двічі однаково.", "The passwords do not match. Type the same password twice.");
pub const zipCrypto = L("Сумісне шифрування (ZipCrypto)", "Compatible encryption (ZipCrypto)");
pub const zipCryptoTip = L(
    "Старе шифрування ZIP, яке відкриває Провідник Windows і старі програми. Слабке: для секретних даних лишайте AES-256.",
    "The old ZIP encryption that Windows Explorer and old tools can open. Weak: keep AES-256 for anything secret.",
);
pub const sfxTip = L(
    "Саморозпаковний архів: .exe, що розпаковується сам, без MakePack. Лише 7z, без томів.",
    "Self-extracting archive: an .exe that unpacks itself, no MakePack needed. 7z only, no volumes.",
);
pub const separateArchives = L("Кожен об'єкт в окремий архів", "Each item to a separate archive");
pub const overwriteManyFmt = L("Ці архіви ({0}) уже існують:\n{1}\n\nПерезаписати?", "These archives ({0}) already exist:\n{1}\n\nOverwrite them?");
pub const testAfter = L("Перевірити архів після створення", "Test the archive when done");
pub const deleteSources = L("Вилучити вихідні файли (у Кошик)", "Delete source files (to Recycle Bin)");
pub const advancedOptions = L("Додатково", "Advanced");
pub const method = L("Метод:", "Method:");
pub const dictionary = L("Словник:", "Dictionary:");
pub const solidBlock = L("Суцільно:", "Solid:");
pub const threads = L("Потоки:", "Threads:");
pub const exeFilter = L("Фільтр exe:", "Exe filter:");
pub const auto = L("Авто", "Auto");
pub const off = L("Вимкнено", "Off");
pub const pickFolder = L("Оберіть теку", "Choose a folder");

/// Compression levels, in CompressionLevel order (None, Fast, Low, Normal, High, Ultra).
pub fn levels() [6][:0]const u8 {
    return if (uk)
        .{ "Без стиснення", "Найшвидший", "Швидкий", "Звичайний", "Максимальний", "Ультра" }
    else
        .{ "Store", "Fastest", "Fast", "Normal", "Maximum", "Ultra" };
}

// operations
pub const extracting = L("Розпакування", "Extracting");
pub const extractingNofM = L("Розпакування {0}/{1}: {2}", "Extracting {0}/{1}: {2}");
pub const compressing = L("Стиснення", "Compressing");
pub const testing = L("Перевірка", "Testing");
pub const deleting = L("Вилучення", "Deleting");
pub const adding = L("Додавання", "Adding");
pub const renaming = L("Перейменування", "Renaming");

// messages
pub const @"error" = L("Помилка", "Error");
pub const cannotOpen = L("Не вдалося відкрити архів.", "Cannot open the archive.");
pub const cancelled = L("Скасовано.", "Cancelled.");
pub const notAnArchive = L("Це не архів або формат не підтримується.", "This is not an archive, or the format is not supported.");
pub const damaged = L("Файл пошкоджено.", "The file is damaged.");
pub const fileNotFoundFmt = L("Файл не знайдено: {0}", "File not found: {0}");
pub const wrongPassword = L("Неправильний пароль.", "Wrong password.");
pub const passwordNeeded = L(
    "Архів зашифровано. Задайте пароль ключем -p (запит) або змінною оточення MAKEPACK_PASSWORD.",
    "The archive is encrypted. Give the password with -p (prompt) or the MAKEPACK_PASSWORD environment variable.",
);
pub const cliPasswordInArgs = L(
    "Пароль в аргументах не приймається: його видно в історії команд і списку процесів. Використайте -p без значення або змінну MAKEPACK_PASSWORD.",
    "A password in the arguments is refused: it shows in the command history and the process list. Use -p without a value or the MAKEPACK_PASSWORD variable.",
);
pub const cliBadSwitchFmt = L("Невідомий або неправильний ключ: {0}", "Unknown or invalid switch: {0}");
pub const cliExistsFmt = L("{0} уже існує. Додайте -y, щоб перезаписати.", "{0} already exists. Add -y to overwrite it.");
pub const cliNoMatchFmt = L("Нічого не знайдено: {0}", "Nothing matches: {0}");
pub const cliNoPasswordFmt = L("Формат {0} не підтримує пароль.", "The {0} format cannot take a password.");
pub const wrongPasswordRetry = L("Неправильний пароль. Спробуйте ще раз:", "Wrong password. Try again:");
pub const dataErrorEncrypted = L(
    "Помилка даних у зашифрованому файлі — найімовірніше, неправильний пароль.",
    "Data error in an encrypted file - most likely a wrong password.",
);
pub const unsupportedMethod = L("Непідтримуваний метод стиснення.", "Unsupported compression method.");
pub const operationFailed = L("Не вдалося виконати операцію", "The operation failed");
pub const unsafeSkippedFmt = L(
    "Пропущено {0} записів із небезпечними шляхами (спроба виходу за межі теки).",
    "{0} entries with unsafe paths were skipped (path traversal attempt).",
);
pub const overwriteArchiveFmt = L("Файл «{0}» уже існує. Перезаписати?", "The file '{0}' already exists. Overwrite?");
pub const testOk = L("Архів у порядку.", "The archive is OK.");
pub const testFailed = L("Архів пошкоджено.", "The archive is damaged.");
pub const notSupported = L("Дія не підтримується для цього формату.", "This operation is not supported for this format.");
pub const offerNewArchive = L("Створити з цих файлів новий архів?", "Create a new archive from these files instead?");
pub const replace = L("Замінити", "Replace");
pub const badName = L("Назва не може бути порожньою чи містити символи / \\ : * ? \" < > |", "A name cannot be empty or contain / \\ : * ? \" < > |");
pub const nameTaken = L("Тут уже є об'єкт із такою назвою.", "An item with this name already exists here.");
pub const confirmDelete = L("Вилучити вибрані об'єкти з архіву?", "Delete the selected items from the archive?");
pub const noInputs = L("Додайте хоча б один файл або теку.", "Add at least one file or folder.");
pub const dictionaryTooBigFmt = L(
    "Словник {0} потребує близько {1} пам'яті, а в системі {2}. Оберіть менший словник.",
    "A {0} dictionary needs about {1} of memory, and this PC has {2}. Choose a smaller dictionary.",
);
pub const infoTitleFmt = L("Відомості — {0}", "Info - {0}");
pub const infoFile = L("Файл", "File");
pub const property = L("Властивість", "Property");
pub const value = L("Значення", "Value");
pub const folders = L("Тек", "Folders");
pub const ratio = L("Стиснення", "Ratio");
pub const volumesCount = L("Томів", "Volumes");
pub const comment = L("Коментар", "Comment");
pub const blocksFmt = L("блоків: {0}", "{0} blocks");
pub const encryptedData = L("так, вміст", "yes, the contents");
pub const encryptedDataAndNames = L("так, вміст і імена файлів", "yes, contents and file names");
pub const copyButton = L("Копіювати", "Copy");
pub const close = L("Закрити", "Close");
pub const filesHeading = L("Файли", "Files");
pub const reportMenu = L("Звіт", "Report");
pub const reportHtml = L("Зберегти як HTML…", "Save as HTML…");
pub const reportTxt = L("Зберегти як текст…", "Save as text…");
pub const reportCopy = L("Копіювати в буфер обміну", "Copy to clipboard");
pub const reportSuffix = L(" - звіт", " - report");
pub const reportSavedFmt = L("Звіт збережено: {0}", "Report saved: {0}");
pub const reportCopied = L("Звіт скопійовано в буфер обміну", "Report copied to the clipboard");
pub const textFiles = L("Текст", "Text");
pub const convertMenu = L("Конвертувати…", "Convert…");
pub const convertTitle = L("Конвертування архівів", "Convert archives");
pub const convertArchives = L("Архіви:", "Archives:");
pub const convertFolder = L("Тека для нових архівів:", "Folder for the new archives:");
pub const nextToOriginals = L("поруч з оригіналами", "next to the originals");
pub const keepIfNotSmaller = L("Залишити старий архів, якщо новий не менший", "Keep the old archive if the new one is not smaller");
pub const deleteOriginals = L("Вилучити оригінали після конвертування (у Кошик)", "Delete the originals once converted (to Recycle Bin)");
pub const skipEncrypted = L("Пропускати зашифровані архіви", "Skip encrypted archives");
pub const convertButton = L("Конвертувати", "Convert");
pub const converting = L("Конвертування", "Converting");
pub const convertSummaryFmt = L(
    "Конвертовано: {0}\nЗалишено старих (новий не менший): {1}\nПропущено: {2}\nПомилок: {3}",
    "Converted: {0}\nOld ones kept (the new one was not smaller): {1}\nSkipped: {2}\nErrors: {3}",
);
pub const convertMismatch = L(
    "Новий архів не пройшов перевірку або в ньому інша кількість чи розмір файлів. Його вилучено, оригінал не змінено.",
    "The new archive failed its test or holds a different number or size of files. It was removed; the original is untouched.",
);
pub const convertWouldDecryptFmt = L(
    "Архів зашифровано, а формат {0} не підтримує пароль: конвертація розкрила б дані. Оберіть 7z або zip.",
    "The archive is encrypted and {0} cannot take a password: converting would expose the data. Choose 7z or zip.",
);
pub const testAfterFailed = L(
    "Архів створено, але перевірка знайшла помилки. Вихідні файли не вилучено.",
    "The archive was created, but the test found errors. The source files were not deleted.",
);
pub const archiveInsideSources = L(
    "Архів створюється всередині теки, яку треба вилучити після архівації. Оберіть інше місце для архіву.",
    "The archive would be created inside a folder that is to be deleted afterwards. Choose another place for it.",
);
pub const recycleFailedFmt = L(
    "Архів створено, але не всі вихідні файли вдалося перемістити до Кошика (код {0}).",
    "The archive was created, but not all source files could be moved to the Recycle Bin (code {0}).",
);
pub const singleFileOnly = L("Цей формат приймає лише один файл.", "This format accepts a single file only.");
pub const fileExists = L("Файл уже існує", "File already exists");
pub const applyToAll = L("Застосувати до всіх", "Apply to all");
pub const solid = L("Суцільний", "Solid");
pub const encrypted = L("Зашифрований", "Encrypted");
pub const files = L("Файлів", "Files");
pub const @"packed" = L("Стиснуто", "Packed");
pub const unpacked = L("Розпаковано", "Unpacked");
pub const yes = L("так", "yes");
pub const no = L("ні", "no");
pub const archives = L("Архіви", "Archives");
pub const allFiles = L("Усі файли", "All files");

// settings dialog
pub const settingsTitle = L("Налаштування", "Settings");
pub const archiveFolder = L("Тека для нових архівів:", "Folder for new archives:");
pub const nextToFiles = L("поруч із файлами", "next to the files");
pub const archiveFolderNote = L(
    "Порожньо — архів створюється поруч із файлами, які пакуються.",
    "Empty - the archive is created next to the files being packed.",
);
pub const motwLabel = L("Позначка «з Інтернету»:", "\"From the Internet\" mark:");
pub const motwNever = L("Не переносити", "Never pass on");
pub const motwRisky = L("Програми, Office, архіви (типово)", "Programs, Office, archives (default)");
pub const motwAll = L("Усі файли", "All files");
pub const motwTip = L(
    "Якщо архів завантажено з Інтернету, розпаковані файли отримують ту саму позначку: Windows попередить перед запуском програми, а Office відкриє документ у захищеному режимі.",
    "When an archive came from the Internet, the extracted files get the same mark: Windows warns before running a program and Office opens documents in Protected View.",
);
pub const resetDefaults = L("Скинути до типових", "Reset to defaults");
pub const resetConfirm = L(
    "Скинути всі налаштування MakePack до типових?",
    "Reset all MakePack settings to their defaults?",
);

// shell verbs and the ProgID description - written into the registry at registration time
pub const progIdDesc = L("Архів MakePack", "MakePack archive");
pub const verbOpenWith = L("Відкрити в MakePack", "Open with MakePack");
pub const verbExtractHere = L("Розпакувати тут", "Extract here");
pub const verbExtractTo = L("Розпакувати в папку\\", "Extract to folder\\");
pub const verbAddTo = L("Додати в архів (MakePack)…", "Add to archive (MakePack)…");
pub const verbQuickAddFmt = L("Додати в {0} (MakePack)", "Add to {0} (MakePack)");
pub const menuQuickAdd = L("Додати в «ім'я.7z» (без діалогу)", "Add to \"name.7z\" (no dialog)");
pub const menuNewArchive = L("Створити → Архів MakePack", "New → MakePack archive");
pub const menuItemsLabel = L("Пункти контекстного меню Провідника:", "Explorer context menu items:");
pub const quickFormat = L("Формат для «Додати в …»:", "Format for \"Add to …\":");

// associations dialog
pub const assocTitle = L("Асоціації файлів", "File associations");
pub const extension = L("Розширення", "Extension");
pub const currentApp = L("Поточна програма", "Current app");
pub const deadSuffix = L(" (програму видалено)", " (app removed)");
pub const userChoiceSuffix = L(" (вибір користувача)", " (user choice)");
pub const selectAll = L("Усі", "All");
pub const selectDefaults = L("Типові", "Default");
pub const selectNone = L("Нічого", "None");
pub const assocNote = L(
    "Для типів, які Windows або інша програма вже закріпили за собою, вибір застосовується одразу; якщо Windows потім скине його, оберіть MakePack у «Відкрити за допомогою → Завжди».",
    "For types already claimed by Windows or another app the choice is applied at once; if Windows later resets it, pick MakePack under 'Open with → Always'.",
);
pub const blockedFmt = L(
    "Windows не дозволив зняти свій вибір для: {0}. Оберіть MakePack вручну через «Відкрити за допомогою → Завжди».",
    "Windows refused to clear its own choice for: {0}. Pick MakePack manually via 'Open with → Always'.",
);

// main window: menus (MAIN_MENU, research notes). '&' marks the WinForms mnemonic: see `plain`.
pub const mFile = L("&Файл", "&File");
pub const mCommands = L("&Команди", "&Commands");
pub const mTools = L("&Інструменти", "Tool&s");
pub const mFavorites = L("&Обране", "Fav&orites");
pub const mOptions = L("&Параметри", "Optio&ns");
pub const mHelp = L("&Довідка", "&Help");
pub const openArchive = L("Відкрити архів…", "Open archive…");
pub const changeDrive = L("Змінити диск", "Change drive");
pub const copyFiles = L("Копіювати файли в буфер", "Copy files to clipboard");
pub const pasteFiles = L("Вставити файли з буфера", "Paste files from clipboard");
pub const copyNames = L("Копіювати повні імена", "Copy full names to clipboard");
pub const selectAllItems = L("Виділити все", "Select all");
pub const selectGroup = L("Виділити групу…", "Select group…");
pub const deselectGroup = L("Зняти виділення групи…", "Deselect group…");
pub const invertSelection = L("Інвертувати виділення", "Invert selection");
pub const exit = L("Вийти", "Exit");
pub const addCmd = L("Додати файли в архів…", "Add files to archive…");
pub const extractTo = L("Розпакувати в…", "Extract to…");
pub const extractNoAsk = L("Розпакувати без підтвердження", "Extract without confirmation");
pub const testCmd = L("Перевірити архів", "Test archived files");
pub const viewCmd = L("Переглянути файл", "View file");
pub const deleteCmd = L("Вилучити файли", "Delete files");
pub const findCmd = L("Знайти файли…", "Find files…");
pub const infoCmd = L("Відомості", "Show information");
pub const addFavorite = L("Додати в обране…", "Add to favorites…");
pub const organizeFavorites = L("Упорядкувати обране…", "Organize favorites…");
pub const fileListMenu = L("Список файлів", "File list");
pub const flatView = L("Плаский вигляд (усі файли архіву)", "Flat folders view");
pub const listMode = L("Список", "List view");
pub const detailsMode = L("Таблиця", "Details");
pub const folderTree = L("Дерево тек", "Folder tree");
pub const about = L("Про MakePack", "About MakePack");
pub const aboutText = L("Архіватор на 7z.dll (7-Zip, LGPL).\nMakeMD", "An archiver on 7z.dll (7-Zip, LGPL).\nMakeMD");

// main window: toolbar (short labels under the icons)
pub const tbAdd = L("Додати", "Add");
pub const tbExtract = L("Розпакувати в", "Extract To");
pub const tbTest = L("Тест", "Test");
pub const tbView = L("Переглянути", "View");
pub const tbDelete = L("Вилучити", "Delete");
pub const tbFind = L("Знайти", "Find");
pub const tbInfo = L("Відомості", "Info");
pub const tbConvert = L("Конвертувати", "Convert");
pub const tbReport = L("Звіт", "Report");

// main window: list, address bar, status bar
pub const crc32 = L("CRC32", "CRC32");
pub const pathColumn = L("Шлях", "Path");
pub const openCmd = L("Відкрити", "Open");
pub const showContents = L("Показати вміст архіву", "Show archive contents");
pub const newFolder = L("Створити теку", "Create a new folder");
pub const newFolderName = L("Нова тека", "New folder");
pub const viewAs = L("Вигляд", "View as");
pub const sortBy = L("Сортувати за", "Sort by");
pub const propertiesCmd = L("Властивості", "Properties");
pub const archiveAddressFmt = L("{0} — архів {1}, розпаковано {2}", "{0} - {1} archive, unpacked size {2}");
pub const totalFmt = L("Разом: {0}", "Total: {0}");
pub const chosenFmt = L("Вибрано: {0}", "Selected: {0}");

/// "1 234 тека/теки/тек" | "1,234 folder(s)" (C# FoldersN).
pub fn foldersN(buf: []u8, n: u64) []const u8 {
    return counted(buf, n, if (uk) plural(n, "тека", "теки", "тек") else if (n == 1) "folder" else "folders");
}

/// "1 234 файл/файли/файлів" | "1,234 file(s)" (C# FilesN).
pub fn filesN(buf: []u8, n: u64) []const u8 {
    return counted(buf, n, if (uk) plural(n, "файл", "файли", "файлів") else if (n == 1) "file" else "files");
}

/// "1 234 байт" | "1,234 byte(s)" (C# Bytes).
pub fn bytes(buf: []u8, n: u64) []const u8 {
    return counted(buf, n, if (uk) "байт" else if (n == 1) "byte" else "bytes");
}

fn counted(buf: []u8, n: u64, noun: []const u8) []const u8 {
    var g: [40]u8 = undefined;
    return std.mem.print(buf, "{s} {s}", .{ group(&g, n), noun }) catch buf[0..0];
}

/// .NET "#,0" / "N0": digits in groups of three with the culture's separator.
pub fn group(buf: *[40]u8, n: u64) []const u8 {
    var digits: [20]u8 = undefined;
    const d: []const u8 = std.mem.print(&digits, "{d}", .{n}) catch unreachable;
    var w: std.Io.Writer = .fixed(buf);
    for (d, 0..) |c, i| {
        if (i > 0 and (d.len - i) % 3 == 0) w.writeAll(group_sep) catch {};
        w.writeByte(c) catch {};
    }
    return w.buffered();
}

/// Ukrainian noun after a number: 1 файл, 2 файли, 5 файлів, 11 файлів, 21 файл.
pub fn plural(n: u64, one: []const u8, few: []const u8, many: []const u8) []const u8 {
    const d = n % 10;
    const h = n % 100;
    if (d == 1 and h != 11) return one;
    if (d >= 2 and d <= 4 and (h < 12 or h > 14)) return few;
    return many;
}

// main window: messages
pub const nothingSelected = L("Нічого не вибрано. Виділіть файли для цієї дії.", "No files selected. Select files for this operation.");
pub const noArchivesSelected = L("Серед вибраного немає архівів.", "There are no archives among the selected files.");
pub const confirmRecycleFmt = L("Перемістити в Кошик: {0}?", "Move to the Recycle Bin: {0}?");
pub const confirmNukeFmt = L("Вилучити НАЗАВЖДИ, без Кошика: {0}?\n\nЦе не можна скасувати.", "Delete PERMANENTLY, bypassing the Recycle Bin: {0}?\n\nThis cannot be undone.");
pub const pathNotFoundFmt = L("Шлях не знайдено:\n{0}", "Path not found:\n{0}");
pub const cannotReadFmt = L("Не вдалося прочитати «{0}»: {1}", "Cannot read '{0}': {1}");
pub const maskPrompt = L("Маска (кілька через ;), напр. *.txt;*.md:", "Mask (several with ;), e.g. *.txt;*.md:");
pub const favoritePrompt = L("Назва в обраному:", "Name in favorites:");
pub const testSummaryFmt = L("Перевірено архівів: {0}. Без помилок: {1}.", "Archives tested: {0}. Without errors: {1}.");
pub const moveUp = L("Вгору", "Move up");
pub const moveDown = L("Вниз", "Move down");

// viewer and Find files windows
pub const mEdit = L("&Правка", "&Edit");
pub const mView = L("&Вигляд", "&View");
pub const copyCmd = L("Копіювати", "Copy");
pub const findText = L("Знайти…", "Find…");
pub const findNext = L("Знайти далі", "Find next");
pub const wordWrap = L("Перенос слів", "Word wrap");
pub const fontCmd = L("Шрифт…", "Font…");
pub const matchCase = L("Враховувати регістр", "Match case");
pub const notFoundFmt = L("«{0}» не знайдено.", "'{0}' not found.");
pub const truncated = L(" (показано перші 16 МБ)", " (first 16 MB shown)");
pub const findFilesTitle = L("Пошук файлів", "Find files");
pub const fileMasks = L("Маски файлів:", "File masks:");
pub const textToFind = L("Текст для пошуку:", "Text to find:");
pub const lookIn = L("Шукати в:", "Look in:");
pub const subfolders = L("У підтеках", "Subfolders");
pub const inArchives = L("Шукати в архівах", "Search inside archives");
pub const stop = L("Стоп", "Stop");
pub const locate = L("Показати", "Locate");
pub const fileColumn = L("Файл", "File");
pub const location = L("Розташування", "Location");
pub const foundFmt = L("{0} знайдено", "{0} found");
pub const skippedFmt = L(", пропущено: {0}", ", {0} skipped");

// ---- helpers ------------------------------------------------------------------------------------------

/// string.Format for the *Fmt templates: "{0}".."{9}" become args[0..] (strings as they are, integers in
/// decimal without grouping, like .NET's default). A placeholder without an argument stays as it is.
pub fn write(w: *std.Io.Writer, template: []const u8, args: anytype) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{' and i + 2 < template.len and template[i + 2] == '}' and std.ascii.isDigit(template[i + 1])) {
            const n = template[i + 1] - '0';
            var found = false;
            inline for (args, 0..) |a, k| {
                if (k == n) {
                    found = true;
                    switch (@typeInfo(@TypeOf(a))) {
                        .int, .comptime_int => try w.print("{d}", .{a}),
                        else => try w.print("{s}", .{a}),
                    }
                }
            }
            if (!found) try w.writeAll(template[i .. i + 3]);
            i += 3;
        } else {
            try w.writeByte(template[i]);
            i += 1;
        }
    }
}

/// `write` into a new allocation (caller frees).
pub fn fill(gpa: std.mem.Allocator, template: []const u8, args: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    write(&aw.writer, template, args) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// `write` into `buf`, NUL-terminated for ImGui; cut short (still terminated) when it does not fit.
pub fn fillZ(buf: []u8, template: []const u8, args: anytype) [:0]const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    write(&w, template, args) catch {};
    const n = w.buffered().len;
    buf[n] = 0;
    return buf[0..n :0];
}

/// A menu caption without its WinForms mnemonic: "Tool&s" -> "Tools", "&&" -> "&".
pub fn plain(buf: []u8, s: []const u8) [:0]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n + 1 < buf.len) : (i += 1) {
        if (s[i] == '&') {
            if (i + 1 < s.len and s[i + 1] == '&') i += 1 else continue;
        }
        buf[n] = s[i];
        n += 1;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

// ---- tests ------------------------------------------------------------------------------------------

const tt = std.testing;

test "both languages" {
    const saved = uk;
    defer uk = saved;
    uk = false;
    try tt.expectEqualStrings("Open…", open.get());
    try tt.expectEqualStrings("Store", levels()[0]);
    uk = true;
    try tt.expectEqualStrings("Відкрити…", open.get());
    try tt.expectEqualStrings("Ультра", levels()[5]);
    try tt.expectEqualStrings("Помилка", @"error".get());
    try tt.expectEqualStrings("CRC", crc.get());
}

test "plural and counted nouns" {
    const saved = .{ uk, group_sep };
    defer {
        uk = saved[0];
        group_sep = saved[1];
    }
    for ([_]u64{ 1, 21, 101 }) |n| try tt.expectEqualStrings("файл", plural(n, "файл", "файли", "файлів"));
    for ([_]u64{ 2, 3, 4, 22, 104 }) |n| try tt.expectEqualStrings("файли", plural(n, "файл", "файли", "файлів"));
    for ([_]u64{ 0, 5, 11, 12, 13, 14, 111, 112 }) |n| try tt.expectEqualStrings("файлів", plural(n, "файл", "файли", "файлів"));

    var buf: [64]u8 = undefined;
    uk = false;
    group_sep = ",";
    try tt.expectEqualStrings("1 file", filesN(&buf, 1));
    try tt.expectEqualStrings("1,234,567 bytes", bytes(&buf, 1234567));
    try tt.expectEqualStrings("0 folders", foldersN(&buf, 0));
    uk = true;
    group_sep = "\u{00A0}";
    try tt.expectEqualStrings("12\u{00A0}345 тек", foldersN(&buf, 12345));
    try tt.expectEqualStrings("2 файли", filesN(&buf, 2));
    try tt.expectEqualStrings("1 байт", bytes(&buf, 1));
    var g: [40]u8 = undefined;
    try tt.expectEqualStrings("999", group(&g, 999));
    try tt.expectEqualStrings("1\u{00A0}000", group(&g, 1000));
}

test "fill templates" {
    const saved = uk;
    defer uk = saved;
    uk = false;
    const s = try fill(tt.allocator, extractingNofM.get(), .{ 2, @as(u64, 10), "a.7z" });
    defer tt.allocator.free(s);
    try tt.expectEqualStrings("Extracting 2/10: a.7z", s);
    var buf: [16]u8 = undefined;
    try tt.expectEqualStrings("Added: x", fillZ(&buf, addedFmt.get(), .{"x"}));
    const cut = fillZ(&buf, deletedFmt.get(), .{"1234567890"});
    try tt.expect(cut.len <= 15 and std.mem.startsWith(u8, cut, "Deleted: ") and cut.ptr[cut.len] == 0);
    try tt.expectEqualStrings("{0} items", fillZ(&buf, itemsFmt.get(), .{})); // a missing arg stays
}

test "plain strips mnemonics" {
    var buf: [32]u8 = undefined;
    try tt.expectEqualStrings("Tools", plain(&buf, "Tool&s"));
    try tt.expectEqualStrings("Файл", plain(&buf, "&Файл"));
    try tt.expectEqualStrings("A&B", plain(&buf, "A&&B"));
}

test "init reads the user's language and separators" {
    const saved = .{ uk, group_sep, decimal_sep };
    defer {
        uk = saved[0];
        group_sep = saved[1];
        decimal_sep = saved[2];
    }
    init();
    try tt.expect(group_sep.len > 0 and decimal_sep.len > 0);
}
