import OSLog

/// Centralized loggers, one per subsystem. Use `Log.foo.debug("...")` etc.
/// Visible in Console.app or `log show --predicate 'subsystem BEGINSWITH "com.felixmatschke.FMail"'`.
enum Log {
    private static let subsystem = "com.felixmatschke.FMail"

    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let mailScripter = Logger(subsystem: subsystem, category: "MailScripter")
    static let fileWatcher = Logger(subsystem: subsystem, category: "FileWatcher")
    static let bodyIndexer = Logger(subsystem: subsystem, category: "BodyIndexer")
    static let db = Logger(subsystem: subsystem, category: "db")
}
