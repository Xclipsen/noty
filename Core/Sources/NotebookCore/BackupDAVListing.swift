import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum BackupDAVListing {
    /// Only direct children of the configured origin/directory are returned.
    public static func names(_ bytes: Data, directory: URL) throws -> [String] {
        guard bytes.count <= 2_000_000 else { throw LibraryArchiveError.invalid }
        return try DAVListingParser.names(bytes, directory: directory)
    }
}

private final class DAVListingParser: NSObject, XMLParserDelegate {
    private var inHref = false
    private var href = ""
    private var hrefs: [String] = []
    static func names(_ bytes: Data, directory: URL) throws -> [String] {
        let delegate = DAVListingParser(), parser = XMLParser(data: bytes)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw LibraryArchiveError.invalid }
        return delegate.hrefs.compactMap { href in
            guard let url = URL(string: href, relativeTo: directory)?.absoluteURL,
                  url.scheme?.lowercased() == directory.scheme?.lowercased(), url.host?.lowercased() == directory.host?.lowercased(), (url.port ?? 443) == (directory.port ?? 443),
                  url.deletingLastPathComponent().standardized.path == directory.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash,
                  !url.hasDirectoryPath, url.query == nil, url.fragment == nil else { return nil }
            return url.lastPathComponent
        }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "href" && namespaceURI == "DAV:" { inHref = true; href = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inHref { href += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "href", inHref { hrefs.append(href); inHref = false }
    }
}
private extension String { var withLeadingSlash: String { "/" + self } }
