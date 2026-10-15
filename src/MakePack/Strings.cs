using System.Globalization;

namespace MakePack;

/// <summary>Every user-visible string. Ukrainian when the UI culture is uk, English otherwise.</summary>
// ponytail: two hardcoded languages instead of .resx satellites; add RESX + ResourceManager if a third language shows up.
static class S
{
    static readonly bool Uk = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "uk";

    public const string App = "MakePack";

    // toolbar / commands
    public static string Open => Uk ? "Відкрити…" : "Open…";
    public static string NewArchive => Uk ? "Новий архів…" : "New archive…";
    public static string Extract => Uk ? "Розпакувати…" : "Extract…";
    public static string Test => Uk ? "Перевірити" : "Test";
    public static string Info => Uk ? "Відомості" : "Info";
    public static string Delete => Uk ? "Вилучити" : "Delete";
    public static string AddToArchive => Uk ? "Додати…" : "Add…";
    public static string AddFilesToArchive => Uk ? "Додати файли…" : "Add files…";
    public static string Assoc => Uk ? "Асоціації…" : "Associations…";
    public static string SettingsMenu => Uk ? "Налаштування…" : "Settings…";
    public static string Up => Uk ? "Вгору" : "Up";
    public static string Browse => Uk ? "Огляд…" : "Browse…";
    public static string Ok => Uk ? "Гаразд" : "OK";
    public static string Cancel => Uk ? "Скасувати" : "Cancel";
    public static string Create => Uk ? "Створити" : "Create";
    public static string Remove => Uk ? "Вилучити" : "Remove";
    public static string AddFiles => Uk ? "+ Файли…" : "+ Files…";
    public static string AddFolder => Uk ? "+ Тека…" : "+ Folder…";

    // list columns
    public static string Name => Uk ? "Назва" : "Name";
    public static string Size => Uk ? "Розмір" : "Size";
    public static string Modified => Uk ? "Змінено" : "Modified";
    public static string Type => Uk ? "Тип" : "Type";
    public static string Crc => "CRC";
    public static string FolderType => Uk ? "<тека>" : "<folder>";

    // status bar
    public static string ItemsFmt => Uk ? "{0} об'єктів" : "{0} items";
    public static string SelectedFmt => Uk ? "{0} вибрано, {1}" : "{0} selected, {1}";
    public static string AddedFmt => Uk ? "Додано: {0}" : "Added: {0}";
    public static string RenamedFmt => Uk ? "Перейменовано: {0}" : "Renamed: {0}";
    public static string DeletedFmt => Uk ? "Вилучено: {0}" : "Deleted: {0}";

    // dialogs
    public static string Password => Uk ? "Пароль" : "Password";
    public static string EnterPassword => Uk ? "Архів зашифровано. Введіть пароль:" : "The archive is encrypted. Enter the password:";
    public static string Destination => Uk ? "Тека призначення:" : "Destination folder:";
    public static string SubFolderFmt => Uk ? "Розпакувати в підтеку «{0}»" : "Extract into subfolder '{0}'";
    public static string Paths => Uk ? "Шляхи:" : "Paths:";
    public static string WithPaths => Uk ? "Зберігати теки" : "Keep folders";
    public static string NoPaths => Uk ? "Без тек (усе в одну)" : "No folders (all in one)";
    public static string Update => Uk ? "Оновлення:" : "Update:";
    public static string UpdateReplace => Uk ? "Розпакувати все" : "Extract all";
    public static string UpdateNewer => Uk ? "Нові й новіші" : "New and newer";
    public static string UpdateExisting => Uk ? "Лише наявні, новіші" : "Existing, if newer";
    public static string UpdateTip => Uk
        ? "«Нові й новіші» не чіпає файли, новіші за копію в архіві. «Лише наявні» оновлює тільки ті файли, що вже є в теці."
        : "\"New and newer\" leaves files that are newer than the archived copy. \"Existing\" only refreshes files already in the folder.";
    public static string KeepBroken => Uk ? "Залишати пошкоджені файли" : "Keep broken files";
    public static string ArchiveAfter => Uk ? "Архів:" : "Archive:";
    public static string DeleteNever => Uk ? "Залишити" : "Keep it";
    public static string DeleteAsk => Uk ? "Запитати, чи вилучити" : "Ask to delete";
    public static string DeleteRecycle => Uk ? "Перемістити в Кошик" : "Move to Recycle Bin";
    public static string DeleteAfterTip => Uk
        ? "Лише коли розпаковано весь архів і без помилок. Для багатотомного — усі частини."
        : "Only when the whole archive was extracted without errors. For a multi-volume set, every part.";
    public static string DeleteArchiveAskFmt => Uk ? "Усе розпаковано. Перемістити «{0}» у Кошик?" : "Everything was extracted. Move '{0}' to the Recycle Bin?";
    public static string IfExists => Uk ? "Якщо файл існує:" : "If a file exists:";
    public static string Ask => Uk ? "Запитати" : "Ask";
    public static string Overwrite => Uk ? "Перезаписати" : "Overwrite";
    public static string Skip => Uk ? "Пропустити" : "Skip";
    public static string Rename => Uk ? "Перейменувати" : "Rename";
    public static string Inputs => Uk ? "Файли й теки:" : "Files and folders:";
    public static string OutputFile => Uk ? "Архів:" : "Archive:";
    public static string Format => Uk ? "Формат:" : "Format:";
    public static string Level => Uk ? "Рівень:" : "Level:";
    public static string EncryptNames => Uk ? "Шифрувати імена файлів" : "Encrypt file names";
    public static string Volumes => Uk ? "Томи:" : "Volumes:";
    public static string VolumesHint => Uk ? "порожньо — один файл" : "empty - a single file";
    public static string BadVolumeSize => Uk
        ? "Розмір тому: число з одиницями, напр. 100 MB, 1,5 GB або 650m. Щонайменше 64 KB."
        : "Volume size: a number with a unit, e.g. 100 MB, 1.5 GB or 650m. At least 64 KB.";
    public static string Profile => Uk ? "Профіль:" : "Profile:";
    public static string SaveProfile => Uk ? "Зберегти…" : "Save…";
    public static string SaveProfileTitle => Uk ? "Зберегти профіль" : "Save profile";
    public static string RenameProfile => Uk ? "Перейменувати профіль" : "Rename profile";
    public static string ProfileName => Uk ? "Назва профілю:" : "Profile name:";
    public static string DefaultProfile => Uk ? "Типовий: підставляти щоразу, коли відкривається «Новий архів»" : "Default: apply whenever New archive opens";
    public static string NoProfile => Uk ? "(без профілю)" : "(no profile)";
    public static string ProfileInMenu => Uk ? "Показувати в меню Провідника (без діалогу)" : "Show in Explorer's menu (no dialog)";
    public static string ProfileInMenuButton => Uk ? "У меню" : "In menu";
    public static string MenuMark => Uk ? " [у меню]" : " [in menu]";
    public static string MenuProfiles => Uk ? "Профілі, позначені «у меню»" : "Profiles marked \"in menu\"";
    public static string VerbProfileFmt => Uk ? "Додати в {0} — «{1}» (MakePack)" : "Add to {0} - \"{1}\" (MakePack)";
    public static string VerbProfileSeparateFmt => Uk ? "Кожен в окремий {0} — «{1}» (MakePack)" : "Each to its own {0} - \"{1}\" (MakePack)";
    public static string DefaultMark => Uk ? " (типовий)" : " (default)";
    public static string ProfileExistsFmt => Uk ? "Профіль «{0}» уже є. Замінити його?" : "A profile named '{0}' already exists. Replace it?";
    public static string ProfileNameTakenFmt => Uk ? "Профіль «{0}» уже є. Оберіть іншу назву." : "A profile named '{0}' already exists. Choose another name.";
    public static string ProfileNotFoundFmt => Uk ? "Профілю «{0}» немає. Створіть його в діалозі «Новий архів»." : "There is no profile named '{0}'. Create it in the New archive dialog.";
    public static string Profiles => Uk ? "Профілі стиснення:" : "Compression profiles:";
    public static string RenameButton => Uk ? "Перейменувати…" : "Rename…";
    public static string MakeDefault => Uk ? "Типовий" : "Default";
    public static string Confirm => Uk ? "Повтор:" : "Confirm:";
    public static string ShowPassword => Uk ? "Показати пароль" : "Show password";
    public static string PasswordsDiffer => Uk ? "Паролі не збігаються. Введіть пароль двічі однаково." : "The passwords do not match. Type the same password twice.";
    public static string ZipCrypto => Uk ? "Сумісне шифрування (ZipCrypto)" : "Compatible encryption (ZipCrypto)";
    public static string ZipCryptoTip => Uk
        ? "Старе шифрування ZIP, яке відкриває Провідник Windows і старі програми. Слабке: для секретних даних лишайте AES-256."
        : "The old ZIP encryption that Windows Explorer and old tools can open. Weak: keep AES-256 for anything secret.";
    public static string SfxTip => Uk
        ? "Саморозпаковний архів: .exe, що розпаковується сам, без MakePack. Лише 7z, без томів."
        : "Self-extracting archive: an .exe that unpacks itself, no MakePack needed. 7z only, no volumes.";
    public static string SeparateArchives => Uk ? "Кожен об'єкт в окремий архів" : "Each item to a separate archive";
    public static string OverwriteManyFmt => Uk ? "Ці архіви ({0}) уже існують:\n{1}\n\nПерезаписати?" : "These archives ({0}) already exist:\n{1}\n\nOverwrite them?";
    public static string TestAfter => Uk ? "Перевірити архів після створення" : "Test the archive when done";
    public static string DeleteSources => Uk ? "Вилучити вихідні файли (у Кошик)" : "Delete source files (to Recycle Bin)";
    public static string AdvancedOptions => Uk ? "Додатково" : "Advanced";
    public static string Method => Uk ? "Метод:" : "Method:";
    public static string Dictionary => Uk ? "Словник:" : "Dictionary:";
    public static string SolidBlock => Uk ? "Суцільно:" : "Solid:";
    public static string Threads => Uk ? "Потоки:" : "Threads:";
    public static string ExeFilter => Uk ? "Фільтр exe:" : "Exe filter:";
    public static string Auto => Uk ? "Авто" : "Auto";
    public static string Off => Uk ? "Вимкнено" : "Off";
    public static string PickFolder => Uk ? "Оберіть теку" : "Choose a folder";

    // compression levels
    public static string[] Levels => Uk
        ? ["Без стиснення", "Найшвидший", "Швидкий", "Звичайний", "Максимальний", "Ультра"]
        : ["Store", "Fastest", "Fast", "Normal", "Maximum", "Ultra"];

    // operations
    public static string Extracting => Uk ? "Розпакування" : "Extracting";
    public static string ExtractingNofM => Uk ? "Розпакування {0}/{1}: {2}" : "Extracting {0}/{1}: {2}";
    public static string Compressing => Uk ? "Стиснення" : "Compressing";
    public static string Testing => Uk ? "Перевірка" : "Testing";
    public static string Deleting => Uk ? "Вилучення" : "Deleting";
    public static string Adding => Uk ? "Додавання" : "Adding";
    public static string Renaming => Uk ? "Перейменування" : "Renaming";

    // messages
    public static string Error => Uk ? "Помилка" : "Error";
    public static string CannotOpen => Uk ? "Не вдалося відкрити архів." : "Cannot open the archive.";
    public static string Cancelled => Uk ? "Скасовано." : "Cancelled.";
    public static string NotAnArchive => Uk ? "Це не архів або формат не підтримується." : "This is not an archive, or the format is not supported.";
    public static string Damaged => Uk ? "Файл пошкоджено." : "The file is damaged.";
    public static string FileNotFoundFmt => Uk ? "Файл не знайдено: {0}" : "File not found: {0}";
    public static string WrongPassword => Uk ? "Неправильний пароль." : "Wrong password.";
    public static string PasswordNeeded => Uk ? "Архів зашифровано. Задайте пароль ключем -p (запит) або змінною оточення MAKEPACK_PASSWORD."
                                              : "The archive is encrypted. Give the password with -p (prompt) or the MAKEPACK_PASSWORD environment variable.";
    public static string CliPasswordInArgs => Uk ? "Пароль в аргументах не приймається: його видно в історії команд і списку процесів. Використайте -p без значення або змінну MAKEPACK_PASSWORD."
                                                 : "A password in the arguments is refused: it shows in the command history and the process list. Use -p without a value or the MAKEPACK_PASSWORD variable.";
    public static string CliBadSwitchFmt => Uk ? "Невідомий або неправильний ключ: {0}" : "Unknown or invalid switch: {0}";
    public static string CliExistsFmt => Uk ? "{0} уже існує. Додайте -y, щоб перезаписати." : "{0} already exists. Add -y to overwrite it.";
    public static string CliNoMatchFmt => Uk ? "Нічого не знайдено: {0}" : "Nothing matches: {0}";
    public static string CliNoPasswordFmt => Uk ? "Формат {0} не підтримує пароль." : "The {0} format cannot take a password.";
    public static string WrongPasswordRetry => Uk ? "Неправильний пароль. Спробуйте ще раз:" : "Wrong password. Try again:";
    public static string DataErrorEncrypted => Uk
        ? "Помилка даних у зашифрованому файлі — найімовірніше, неправильний пароль."
        : "Data error in an encrypted file - most likely a wrong password.";
    public static string UnsupportedMethod => Uk ? "Непідтримуваний метод стиснення." : "Unsupported compression method.";
    public static string OperationFailed => Uk ? "Не вдалося виконати операцію" : "The operation failed";
    public static string UnsafeSkippedFmt => Uk
        ? "Пропущено {0} записів із небезпечними шляхами (спроба виходу за межі теки)."
        : "{0} entries with unsafe paths were skipped (path traversal attempt).";
    public static string OverwriteArchiveFmt => Uk ? "Файл «{0}» уже існує. Перезаписати?" : "The file '{0}' already exists. Overwrite?";
    public static string TestOk => Uk ? "Архів у порядку." : "The archive is OK.";
    public static string TestFailed => Uk ? "Архів пошкоджено." : "The archive is damaged.";
    public static string NotSupported => Uk ? "Дія не підтримується для цього формату." : "This operation is not supported for this format.";
    public static string OfferNewArchive => Uk ? "Створити з цих файлів новий архів?" : "Create a new archive from these files instead?";
    public static string Replace => Uk ? "Замінити" : "Replace";
    public static string BadName => Uk ? "Назва не може бути порожньою чи містити символи / \\ : * ? \" < > |" : "A name cannot be empty or contain / \\ : * ? \" < > |";
    public static string NameTaken => Uk ? "Тут уже є об'єкт із такою назвою." : "An item with this name already exists here.";
    public static string ConfirmDelete =>Uk ? "Вилучити вибрані об'єкти з архіву?" : "Delete the selected items from the archive?";
    public static string NoInputs => Uk ? "Додайте хоча б один файл або теку." : "Add at least one file or folder.";
    public static string DictionaryTooBigFmt => Uk
        ? "Словник {0} потребує близько {1} пам'яті, а в системі {2}. Оберіть менший словник."
        : "A {0} dictionary needs about {1} of memory, and this PC has {2}. Choose a smaller dictionary.";
    public static string InfoTitleFmt => Uk ? "Відомості — {0}" : "Info - {0}";
    public static string InfoFile => Uk ? "Файл" : "File";
    public static string Property => Uk ? "Властивість" : "Property";
    public static string Value => Uk ? "Значення" : "Value";
    public static string Folders => Uk ? "Тек" : "Folders";
    public static string Ratio => Uk ? "Стиснення" : "Ratio";
    public static string VolumesCount => Uk ? "Томів" : "Volumes";
    public static string Comment => Uk ? "Коментар" : "Comment";
    public static string BlocksFmt => Uk ? "блоків: {0}" : "{0} blocks";
    public static string EncryptedData => Uk ? "так, вміст" : "yes, the contents";
    public static string EncryptedDataAndNames => Uk ? "так, вміст і імена файлів" : "yes, contents and file names";
    public static string CopyButton => Uk ? "Копіювати" : "Copy";
    public static string Close => Uk ? "Закрити" : "Close";
    public static string FilesHeading => Uk ? "Файли" : "Files";
    public static string ReportMenu => Uk ? "Звіт" : "Report";
    public static string ReportHtml => Uk ? "Зберегти як HTML…" : "Save as HTML…";
    public static string ReportTxt => Uk ? "Зберегти як текст…" : "Save as text…";
    public static string ReportCopy => Uk ? "Копіювати в буфер обміну" : "Copy to clipboard";
    public static string ReportSuffix => Uk ? " - звіт" : " - report";
    public static string ReportSavedFmt => Uk ? "Звіт збережено: {0}" : "Report saved: {0}";
    public static string ReportCopied => Uk ? "Звіт скопійовано в буфер обміну" : "Report copied to the clipboard";
    public static string TextFiles => Uk ? "Текст" : "Text";
    public static string ConvertMenu => Uk ? "Конвертувати…" : "Convert…";
    public static string ConvertTitle => Uk ? "Конвертування архівів" : "Convert archives";
    public static string ConvertArchives => Uk ? "Архіви:" : "Archives:";
    public static string ConvertFolder => Uk ? "Тека для нових архівів:" : "Folder for the new archives:";
    public static string NextToOriginals => Uk ? "поруч з оригіналами" : "next to the originals";
    public static string KeepIfNotSmaller => Uk ? "Залишити старий архів, якщо новий не менший" : "Keep the old archive if the new one is not smaller";
    public static string DeleteOriginals => Uk ? "Вилучити оригінали після конвертування (у Кошик)" : "Delete the originals once converted (to Recycle Bin)";
    public static string SkipEncrypted => Uk ? "Пропускати зашифровані архіви" : "Skip encrypted archives";
    public static string ConvertButton => Uk ? "Конвертувати" : "Convert";
    public static string Converting => Uk ? "Конвертування" : "Converting";
    public static string ConvertSummaryFmt => Uk
        ? "Конвертовано: {0}\nЗалишено старих (новий не менший): {1}\nПропущено: {2}\nПомилок: {3}"
        : "Converted: {0}\nOld ones kept (the new one was not smaller): {1}\nSkipped: {2}\nErrors: {3}";
    public static string ConvertMismatch => Uk
        ? "Новий архів не пройшов перевірку або в ньому інша кількість чи розмір файлів. Його вилучено, оригінал не змінено."
        : "The new archive failed its test or holds a different number or size of files. It was removed; the original is untouched.";
    public static string ConvertWouldDecryptFmt => Uk
        ? "Архів зашифровано, а формат {0} не підтримує пароль: конвертація розкрила б дані. Оберіть 7z або zip."
        : "The archive is encrypted and {0} cannot take a password: converting would expose the data. Choose 7z or zip.";
    public static string TestAfterFailed => Uk
        ? "Архів створено, але перевірка знайшла помилки. Вихідні файли не вилучено."
        : "The archive was created, but the test found errors. The source files were not deleted.";
    public static string ArchiveInsideSources => Uk
        ? "Архів створюється всередині теки, яку треба вилучити після архівації. Оберіть інше місце для архіву."
        : "The archive would be created inside a folder that is to be deleted afterwards. Choose another place for it.";
    public static string RecycleFailedFmt => Uk
        ? "Архів створено, але не всі вихідні файли вдалося перемістити до Кошика (код {0})."
        : "The archive was created, but not all source files could be moved to the Recycle Bin (code {0}).";
    public static string SingleFileOnly => Uk ? "Цей формат приймає лише один файл." : "This format accepts a single file only.";
    public static string FileExists => Uk ? "Файл уже існує" : "File already exists";
    public static string ApplyToAll => Uk ? "Застосувати до всіх" : "Apply to all";
    public static string Solid => Uk ? "Суцільний" : "Solid";
    public static string Encrypted => Uk ? "Зашифрований" : "Encrypted";
    public static string Files => Uk ? "Файлів" : "Files";
    public static string Packed => Uk ? "Стиснуто" : "Packed";
    public static string Unpacked => Uk ? "Розпаковано" : "Unpacked";
    public static string Yes => Uk ? "так" : "yes";
    public static string No => Uk ? "ні" : "no";
    public static string Archives => Uk ? "Архіви" : "Archives";
    public static string AllFiles => Uk ? "Усі файли" : "All files";

    // settings dialog
    public static string SettingsTitle => Uk ? "Налаштування" : "Settings";
    public static string ArchiveFolder => Uk ? "Тека для нових архівів:" : "Folder for new archives:";
    public static string NextToFiles => Uk ? "поруч із файлами" : "next to the files";
    public static string ArchiveFolderNote => Uk
        ? "Порожньо — архів створюється поруч із файлами, які пакуються."
        : "Empty - the archive is created next to the files being packed.";
    public static string MotwLabel => Uk ? "Позначка «з Інтернету»:" : "\"From the Internet\" mark:";
    public static string MotwNever => Uk ? "Не переносити" : "Never pass on";
    public static string MotwRisky => Uk ? "Програми, Office, архіви (типово)" : "Programs, Office, archives (default)";
    public static string MotwAll => Uk ? "Усі файли" : "All files";
    public static string MotwTip => Uk
        ? "Якщо архів завантажено з Інтернету, розпаковані файли отримують ту саму позначку: Windows попередить перед запуском програми, а Office відкриє документ у захищеному режимі."
        : "When an archive came from the Internet, the extracted files get the same mark: Windows warns before running a program and Office opens documents in Protected View.";
    public static string ResetDefaults => Uk ? "Скинути до типових" : "Reset to defaults";
    public static string ResetConfirm => Uk
        ? "Скинути всі налаштування MakePack до типових?"
        : "Reset all MakePack settings to their defaults?";

    // shell verbs and the ProgID description - written into the registry at registration time
    public static string ProgIdDesc => Uk ? "Архів MakePack" : "MakePack archive";
    public static string VerbOpenWith => Uk ? "Відкрити в MakePack" : "Open with MakePack";
    public static string VerbExtractHere => Uk ? "Розпакувати тут" : "Extract here";
    public static string VerbExtractTo => Uk ? "Розпакувати в папку\\" : "Extract to folder\\";
    public static string VerbAddTo => Uk ? "Додати в архів (MakePack)…" : "Add to archive (MakePack)…";
    public static string VerbQuickAddFmt => Uk ? "Додати в {0} (MakePack)" : "Add to {0} (MakePack)";
    public static string MenuQuickAdd => Uk ? "Додати в «ім'я.7z» (без діалогу)" : "Add to \"name.7z\" (no dialog)";
    public static string MenuNewArchive => Uk ? "Створити → Архів MakePack" : "New → MakePack archive";
    public static string MenuItemsLabel => Uk ? "Пункти контекстного меню Провідника:" : "Explorer context menu items:";
    public static string QuickFormat => Uk ? "Формат для «Додати в …»:" : "Format for \"Add to …\":";

    // associations dialog
    public static string AssocTitle => Uk ? "Асоціації файлів" : "File associations";
    public static string Extension => Uk ? "Розширення" : "Extension";
    public static string CurrentApp => Uk ? "Поточна програма" : "Current app";
    public static string DeadSuffix => Uk ? " (програму видалено)" : " (app removed)";
    public static string UserChoiceSuffix => Uk ? " (вибір користувача)" : " (user choice)";
    public static string SelectAll => Uk ? "Усі" : "All";
    public static string SelectDefaults => Uk ? "Типові" : "Default";
    public static string SelectNone => Uk ? "Нічого" : "None";
    public static string AssocNote => Uk
        ? "Для типів, які Windows або інша програма вже закріпили за собою, вибір застосовується одразу; якщо Windows потім скине його, оберіть MakePack у «Відкрити за допомогою → Завжди»."
        : "For types already claimed by Windows or another app the choice is applied at once; if Windows later resets it, pick MakePack under 'Open with → Always'.";
    public static string BlockedFmt => Uk
        ? "Windows не дозволив зняти свій вибір для: {0}. Оберіть MakePack вручну через «Відкрити за допомогою → Завжди»."
        : "Windows refused to clear its own choice for: {0}. Pick MakePack manually via 'Open with → Always'.";
}
