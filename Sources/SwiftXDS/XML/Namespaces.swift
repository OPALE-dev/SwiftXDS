/// Namespace URIs used by IHE XDS.b and its transports, with the prefixes the writer prefers.
public enum Namespace {
    public static let soapEnvelope = "http://www.w3.org/2003/05/soap-envelope"
    public static let addressing = "http://www.w3.org/2005/08/addressing"
    public static let xop = "http://www.w3.org/2004/08/xop/include"
    public static let xmime = "http://www.w3.org/2005/05/xmlmime"
    public static let xsi = "http://www.w3.org/2001/XMLSchema-instance"
    /// ebRIM 3.0 registry information model.
    public static let rim = "urn:oasis:names:tc:ebxml-regrep:xsd:rim:3.0"
    /// ebRS 3.0 life cycle management (SubmitObjectsRequest, RemoveObjectsRequest).
    public static let lcm = "urn:oasis:names:tc:ebxml-regrep:xsd:lcm:3.0"
    /// ebRS 3.0 query (AdhocQueryRequest, AdhocQueryResponse).
    public static let query = "urn:oasis:names:tc:ebxml-regrep:xsd:query:3.0"
    /// ebRS 3.0 registry services (RegistryResponse, RegistryErrorList).
    public static let rs = "urn:oasis:names:tc:ebxml-regrep:xsd:rs:3.0"
    /// IHE XDS.b messages (ProvideAndRegisterDocumentSetRequest, RetrieveDocumentSetRequest…).
    public static let xdsb = "urn:ihe:iti:xds-b:2007"
    /// IHE Restricted Metadata Update (ITI-57).
    public static let rmd = "urn:ihe:iti:rmd:2017"

    /// Prefixes used on output when the namespace appears in a document. Others get `ns1`, `ns2`…
    public static let preferredPrefixes: [String: String] = [
        soapEnvelope: "soap",
        addressing: "wsa",
        xop: "xop",
        xmime: "xmime",
        xsi: "xsi",
        rim: "rim",
        lcm: "lcm",
        query: "query",
        rs: "rs",
        xdsb: "xdsb",
        rmd: "rmd",
    ]
}
