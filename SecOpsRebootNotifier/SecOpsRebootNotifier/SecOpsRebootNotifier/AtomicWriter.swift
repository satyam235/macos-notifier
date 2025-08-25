import Foundation

/// Simple atomic writer (mkstemp + rename) without extra metrics.
/// Uses ~/Library/Logs/SecOpsRebootNotifier by default via ActionLogger.
final class AtomicWriter {
    
    struct AtomicWriterError: Error, CustomNSError, CustomStringConvertible {
        static var errorDomain: String { "AtomicWriter" }
        let message: String
        let errnoCode: Int32?
        var errorCode: Int { Int(errnoCode ?? -1) }
        var errorUserInfo: [String : Any] {
            var d: [String: Any] = [NSLocalizedDescriptionKey: message]
            if let e = errnoCode {
                d["errno"] = e
                d["errno_description"] = String(cString: strerror(e))
            }
            return d
        }
        var description: String {
            if let e = errnoCode {
                return "AtomicWriterError(message: \"\(message)\", errno: \(e) \(String(cString: strerror(e))) )"
            }
            return "AtomicWriterError(message: \"\(message)\")"
        }
    }
    
    private let fm = FileManager.default
    
    func writeAtomic(data: Data, toPath rawPath: String, permissions: Int16? = nil) throws {
        let path = (rawPath as NSString).expandingTildeInPath
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AtomicWriterError(message: "Destination path empty", errnoCode: nil)
        }
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        
        // mkstemp pattern
        var template = path + ".tmp.XXXXXX"
        var cTemplate = Array(template.utf8CString)
        let fd = cTemplate.withUnsafeMutableBufferPointer { ptr -> Int32 in
            mkstemp(ptr.baseAddress)
        }
        guard fd != -1 else {
            throw AtomicWriterError(message: "mkstemp failed creating template near \(path)", errnoCode: errno)
        }
        let tmpPath = String(cString: cTemplate)
        
        // Write bytes (use Darwin.write to avoid collision with this class method name)
        let written = data.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress else { return 0 }
            return Darwin.write(fd, base, rawBuf.count)
        }
        if written != data.count {
            let e = errno
            close(fd)
            _ = try? fm.removeItem(atPath: tmpPath)
            throw AtomicWriterError(message: "Short write \(written)/\(data.count) to \(tmpPath)", errnoCode: e)
        }
        fsync(fd)
        close(fd)
        
        if let perms = permissions {
            try fm.setAttributes([.posixPermissions: NSNumber(value: perms)], ofItemAtPath: tmpPath)
        }
        
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            _ = try? fm.removeItem(atPath: tmpPath)
            throw AtomicWriterError(message: "Destination \(path) is a directory", errnoCode: nil)
        }
        if fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
        try fm.moveItem(atPath: tmpPath, toPath: path)
    }
}