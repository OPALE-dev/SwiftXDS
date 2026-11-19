import Foundation
import Testing
@testable import SwiftXDS

@Suite struct XMLTests {
    let rim = Namespace.rim

    @Test func roundTripKeepsNamesAttributesAndText() throws {
        let tree = XElement(XName(rim, "Slot"), attributes: [XAttribute(XName("name"), "creationTime")], elements: [
            XElement(XName(rim, "ValueList"), elements: [
                XElement(XName(rim, "Value"), text: "20261119"),
                XElement(XName(rim, "Value"), text: "a < b & \"c\" > d"),
            ]),
        ])
        let xml = try XMLWriter.string(tree)
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?><rim:Slot xmlns:rim=\"\(rim)\" name=\"creationTime\">"))
        #expect(xml.contains("a &lt; b &amp; \"c\" &gt; d"))
        #expect(try XMLReader.parse(xml) == tree)
    }

    @Test func prefixesComeFromTheDocumentNotTheTree() throws {
        // Same namespaces, other prefixes and a default namespace: same tree.
        let xml = """
        <x:Slot xmlns:x="\(rim)" name="n"><ValueList xmlns="\(rim)"><Value>v</Value></ValueList></x:Slot>
        """
        let tree = try XMLReader.parse(xml)
        #expect(tree.name == XName(rim, "Slot"))
        #expect(tree.element(named: XName(rim, "ValueList"))?.element(named: XName(rim, "Value"))?.text == "v")
    }

    @Test func namespacedAttributesAreResolved() throws {
        let xml = """
        <a xmlns:s="http://www.w3.org/2003/05/soap-envelope" s:mustUnderstand="1" plain="p"/>
        """
        let tree = try XMLReader.parse(xml)
        #expect(tree.attribute(XName(Namespace.soapEnvelope, "mustUnderstand")) == "1")
        #expect(tree.attribute("plain") == "p")
        #expect(tree.attributes.count == 2)
    }

    @Test func whitespaceBetweenElementsIsDropped() throws {
        let tree = try XMLReader.parse("<a>\n  <b> x </b>\n  <c/>\n</a>")
        #expect(tree.children.count == 2)
        #expect(tree.element(named: XName("b"))?.text == " x ")
        #expect(tree.element(named: XName("b"))?.trimmedText == "x")
    }

    @Test func cdataAndEntitiesBecomeText() throws {
        let tree = try XMLReader.parse("<a><![CDATA[<raw>]]>&amp;&#233;</a>")
        #expect(tree.text == "<raw>&é")
    }

    @Test func attributeWhitespaceSurvivesARoundTrip() throws {
        let tree = XElement(XName("a"), attributes: [XAttribute(XName("v"), "line1\nline2\tend")])
        #expect(try XMLReader.parse(XMLWriter.data(tree)) == tree)
    }

    @Test func xmlLangUsesTheReservedPrefix() throws {
        let tree = XElement(XName("t"), attributes: [XAttribute(XName(XMLWriter.xmlNamespace, "lang"), "fr")], text: "x")
        let xml = try XMLWriter.string(tree, declaration: false)
        #expect(xml == "<t xml:lang=\"fr\">x</t>")
        #expect(try XMLReader.parse(xml) == tree)
    }

    @Test func unknownNamespacesGetGeneratedPrefixes() throws {
        let tree = XElement(XName("urn:a", "x"), elements: [XElement(XName("urn:b", "y"))])
        #expect(try XMLWriter.string(tree, declaration: false) == "<ns1:x xmlns:ns1=\"urn:a\" xmlns:ns2=\"urn:b\"><ns2:y/></ns1:x>")
    }

    @Test func controlCharactersAreRefused() {
        let tree = XElement(XName("a"), text: "bad\u{1}")
        #expect(throws: XMLError.invalidCharacter(1)) { try XMLWriter.data(tree) }
    }

    @Test func invalidNamesAreRefused() {
        #expect(throws: XMLError.invalidName("a b")) { try XMLWriter.data(XElement(XName("a b"))) }
        #expect(throws: XMLError.invalidName("")) { try XMLWriter.data(XElement(XName(""))) }
    }

    @Test func doctypeIsRefused() {
        let bomb = """
        <?xml version="1.0"?><!DOCTYPE a [<!ENTITY x "xxxxxxxx"><!ENTITY y "&x;&x;&x;&x;">]><a>&y;</a>
        """
        #expect(throws: XMLError.doctypeRefused) { try XMLReader.parse(bomb) }
    }

    @Test func limitsAreApplied() {
        #expect(throws: XMLError.tooLarge(limit: 10)) { try XMLReader.parse("<a>0123456789</a>", limits: .init(maxBytes: 10)) }
        #expect(throws: XMLError.tooDeep(limit: 2)) { try XMLReader.parse("<a><b><c/></b></a>", limits: .init(maxDepth: 2)) }
        #expect(throws: XMLError.empty) { try XMLReader.parse(Data()) }
    }

    @Test func malformedXMLReportsAPosition() {
        do {
            _ = try XMLReader.parse("<a><b></a>")
            Issue.record("parsed malformed XML")
        } catch let XMLError.malformed(_, line, _) {
            #expect(line >= 1)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func descendantsAreFoundInDocumentOrder() throws {
        let tree = try XMLReader.parse("<a><v>1</v><b><v>2</v><c><v>3</v></c></b></a>")
        #expect(tree.descendants(named: XName("v")).map(\.text) == ["1", "2", "3"])
    }

    @Test func setAttributeReplacesAndRemoves() {
        var e = XElement(XName("a"), attributes: [XAttribute(XName("k"), "1")])
        e.setAttribute(XName("k"), "2")
        #expect(e.attributes == [XAttribute(XName("k"), "2")])
        e.setAttribute(XName("k"), nil)
        #expect(e.attributes.isEmpty)
    }
}

@Suite struct XMLHardeningTests {
    @Test func utf16IsRefusedSoThatADoctypeCannotHide() {
        let doc = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE a [<!ATTLIST a injected CDATA \"yes\">]><a/>"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(doc.data(using: .utf16LittleEndian)!)
        #expect(throws: XMLError.unsupportedEncoding("UTF-16 or UTF-32")) { try XMLReader.parse(utf16) }
        #expect(throws: XMLError.unsupportedEncoding("UTF-16 or UTF-32")) { try XMLReader.parse(doc.data(using: .utf16BigEndian)!) }
        #expect(throws: XMLError.unsupportedEncoding("ISO-8859-1")) { try XMLReader.parse("<?xml version='1.0' encoding='ISO-8859-1'?><a/>") }
    }

    @Test func utf8DeclarationsAndBOMAreAccepted() throws {
        #expect(try XMLReader.parse("<?xml version='1.0' encoding='utf-8'?><a/>").name == XName("a"))
        #expect(try XMLReader.parse(Data([0xEF, 0xBB, 0xBF]) + Data("<a/>".utf8)).name == XName("a"))
    }

    @Test(arguments: [#"<a p:x="1"/>"#, #"<p:a/>"#, #"<a xmlns:q="urn:q"><b p:x="1"/></a>"#])
    func undeclaredPrefixesAreRefused(xml: String) {
        // Same error on macOS and Linux; the prefix name depends on the parser's message.
        do {
            _ = try XMLReader.parse(xml)
            Issue.record("accepted an undeclared prefix")
        } catch XMLError.undeclaredPrefix(let p) {
            #expect(p.isEmpty || p.hasPrefix("p"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func qnamesInTextAreResolvedInScope() throws {
        let tree = try XMLReader.parse(#"<a xmlns:s="urn:s" xmlns="urn:d"><v>s:Sender</v><w>Plain</w></a>"#)
        let v = try #require(tree.elements.first)
        #expect(v.resolveQName(v.text) == XName("urn:s", "Sender"))
        #expect(tree.elements[1].resolveQName("Plain") == XName("urn:d", "Plain"))
        #expect(v.resolveQName("u:x") == nil)
    }

    @Test func qnameAndRawNodesAreWritten() throws {
        let tree = XElement(XName("urn:a", "v"), children: [.qname(XName("urn:b", "Code")), .raw("<x:y xmlns:x=\"urn:x\"/>")])
        #expect(try XMLWriter.string(tree, declaration: false) == #"<ns1:v xmlns:ns1="urn:a" xmlns:ns2="urn:b">ns2:Code<x:y xmlns:x="urn:x"/></ns1:v>"#)
    }
}
