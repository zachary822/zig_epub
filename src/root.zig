const std = @import("std");
const ZipFile = @import("zig_zip").ZipFile;
const c = @cImport({
    @cInclude("libxml/tree.h");
});
const testing = std.testing;

pub const Epub = struct {
    allocator: std.mem.Allocator,
    chapters: std.ArrayList(Chapter),
    zip_file: ZipFile,
    content: std.ArrayList(u8),

    title: [:0]const u8,
    author: [:0]const u8,
    id: [:0]const u8,
    langage: [:0]const u8 = "en",

    const Self = @This();

    const Chapter = struct {
        filename: []const u8,
        content: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, title: [:0]const u8, author: [:0]const u8, id: [:0]const u8) Self {
        const zip_file = ZipFile.init(allocator);
        return .{
            .allocator = allocator,
            .chapters = .empty,
            .title = title,
            .author = author,
            .id = id,
            .zip_file = zip_file,
            .content = zip_file.output_buff,
        };
    }

    pub fn deinit(self: *Self) void {
        self.zip_file.deinit();
        for (self.chapters.items) |file| {
            self.allocator.free(file.filename);
            self.allocator.free(file.content);
        }
        self.chapters.deinit(self.allocator);
    }

    pub fn finish(self: *Self) !void {
        try self.zip_file.addFile("mimetype", "application/epub+zip", .{ .compression_method = .store });

        // container
        var container: std.ArrayList(u8) = .empty;
        defer container.deinit(self.allocator);
        {
            const doc = c.xmlNewDoc(null);
            defer _ = c.xmlFreeDoc(doc);

            const root = c.xmlNewNode(null, "container");
            const ns = c.xmlNewNs(root, "urn:oasis:names:tc:opendocument:xmlns:container", null);
            c.xmlSetNs(root, ns);
            _ = c.xmlSetProp(root, "version", "1.0");
            _ = c.xmlDocSetRootElement(doc, root);

            const rootfiles = c.xmlNewNode(ns, "rootfiles");
            _ = c.xmlAddChild(root, rootfiles);

            const rootfile = c.xmlNewChild(rootfiles, ns, "rootfile", null);
            _ = c.xmlNewProp(rootfile, "full-path", "OEBPS/content.opf");
            _ = c.xmlNewProp(rootfile, "media-type", "application/oebps-package+xml");

            var xml_buff: [*c]u8 = undefined;
            defer c.xmlFree.?(xml_buff);
            var buffsize: i32 = undefined;
            c.xmlDocDumpMemoryEnc(doc, &xml_buff, &buffsize, "UTF-8");

            try container.appendSlice(self.allocator, xml_buff[0..@intCast(buffsize)]);
        }

        try self.zip_file.addFile("META-INF/container.xml", container.items, .{});

        // write metadata
        var opf_data: std.ArrayList(u8) = .empty;
        defer opf_data.deinit(self.allocator);

        // write toc
        var toc_data: std.ArrayList(u8) = .empty;
        defer toc_data.deinit(self.allocator);

        {
            // toc
            const toc = c.xmlNewDoc(null);
            defer _ = c.xmlFreeDoc(toc);

            _ = c.xmlCreateIntSubset(toc, "html", "-//W3C//DTD XHTML 1.0 Strict//EN", "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd");

            const root = c.xmlNewNode(null, "html");
            const ns_xhtml = c.xmlNewNs(root, "http://www.w3.org/1999/xhtml", null);
            const ns_epub = c.xmlNewNs(root, "http://www.idpf.org/2007/ops", "epub");
            _ = c.xmlNewProp(root, "lang", "en");
            _ = c.xmlDocSetRootElement(toc, root);

            const head = c.xmlNewChild(root, ns_xhtml, "head", null);
            _ = c.xmlNewChild(head, ns_xhtml, "title", "Table of Contents");
            const meta = c.xmlNewChild(head, ns_xhtml, "meta", null);
            _ = c.xmlNewProp(meta, "http-equiv", "Content-Type");
            _ = c.xmlNewProp(meta, "content", "application/xhtml+xml; charset=utf-8");

            const body = c.xmlNewChild(root, null, "body", null);
            const nav = c.xmlNewChild(body, ns_xhtml, "nav", null);
            _ = c.xmlNewProp(nav, "id", "toc");
            _ = c.xmlNewNsProp(nav, ns_epub, "type", "toc");

            _ = c.xmlNewChild(nav, ns_xhtml, "h1", "Table of Contents");
            const toc_ol = c.xmlNewChild(nav, ns_xhtml, "ol", null);

            // content opf
            const doc = c.xmlNewDoc(null);
            defer _ = c.xmlFreeDoc(doc);

            const package = c.xmlNewNode(null, "package");
            const ns = c.xmlNewNs(package, "http://www.idpf.org/2007/opf", null);
            c.xmlSetNs(package, ns);
            _ = c.xmlSetProp(package, "version", "3.0");
            _ = c.xmlSetProp(package, "unique-identifier", "BookId");
            _ = c.xmlDocSetRootElement(doc, package);

            // metadata
            const metadata = c.xmlNewChild(package, ns, "metadata", null);
            const ns_dc = c.xmlNewNs(metadata, "http://purl.org/dc/elements/1.1/", "dc");
            _ = c.xmlNewNs(metadata, "http://www.idpf.org/2007/opf", "opf");

            _ = c.xmlNewChild(metadata, ns_dc, "title", self.title);
            _ = c.xmlNewChild(metadata, ns_dc, "language", self.langage);
            _ = c.xmlNewChild(metadata, ns_dc, "identifier", self.id);
            _ = c.xmlNewChild(metadata, ns_dc, "creator", self.author);

            // manifest and spine
            const manifest = c.xmlNewChild(package, ns, "manifest", null);

            const toc_item = c.xmlNewChild(manifest, ns, "item", null);
            _ = c.xmlNewProp(toc_item, "href", "nav.xhtml");
            _ = c.xmlNewProp(toc_item, "media-type", "application/xhtml+xml");
            _ = c.xmlNewProp(toc_item, "properties", "nav");

            const spine = c.xmlNewChild(package, ns, "spine", null);

            const toc_itemref = c.xmlNewChild(spine, ns, "itemref", null);
            _ = c.xmlNewProp(toc_itemref, "idref", "nav");

            for (self.chapters.items) |file| {
                const item = c.xmlNewChild(manifest, ns, "item", null);

                const id = try self.allocator.dupeZ(u8, std.fs.path.stem(file.filename));
                defer self.allocator.free(id);
                const href = try self.allocator.dupeZ(u8, std.fs.path.basename(file.filename));
                defer self.allocator.free(href);

                _ = c.xmlNewProp(item, "id", id);
                _ = c.xmlNewProp(item, "href", href);

                const ext = std.fs.path.extension(file.filename);
                var mimetype: [:0]const u8 = undefined;
                if (std.mem.eql(u8, ext, ".xhtml")) {
                    mimetype = "application/xhtml+xml";
                } else if (std.mem.eql(u8, ext, ".css")) {
                    mimetype = "text/css";
                } else {
                    mimetype = "";
                }
                _ = c.xmlNewProp(item, "media-type", mimetype);

                // add chapter
                const itemref = c.xmlNewChild(spine, ns, "itemref", null);
                _ = c.xmlNewProp(itemref, "idref", id);

                // add toc entry
                const li = c.xmlNewChild(toc_ol, ns_xhtml, "li", null);
                const a = c.xmlNewChild(li, ns_xhtml, "a", id);
                _ = c.xmlNewProp(a, "href", href);
            }

            {
                var xml_buff: [*c]u8 = undefined;
                defer c.xmlFree.?(xml_buff);
                var buffsize: i32 = undefined;
                c.xmlDocDumpMemoryEnc(doc, &xml_buff, &buffsize, "UTF-8");

                try opf_data.appendSlice(self.allocator, xml_buff[0..@intCast(buffsize)]);
            }
            {
                var xml_buff: [*c]u8 = undefined;
                defer c.xmlFree.?(xml_buff);
                var buffsize: i32 = undefined;
                c.xmlDocDumpMemoryEnc(toc, &xml_buff, &buffsize, "UTF-8");

                try toc_data.appendSlice(self.allocator, xml_buff[0..@intCast(buffsize)]);
            }
        }

        try self.zip_file.addFile("OEBPS/content.opf", opf_data.items, .{});
        try self.zip_file.addFile("OEBPS/nav.xhtml", toc_data.items, .{});

        for (self.chapters.items) |file| {
            try self.zip_file.addFile(file.filename, file.content, .{});
        }

        try self.zip_file.finish();
    }

    pub fn addFile(self: *Self, name: []const u8, content: []const u8) !void {
        try self.chapters.append(self.allocator, .{
            .filename = try self.allocator.dupe(u8, name),
            .content = try self.allocator.dupe(u8, content),
        });
    }
};

test "can init/deinit" {
    var epub = Epub.init(testing.allocator, "test title", "test author", "123");
    defer epub.deinit();

    try epub.addFile("OEBPS/chapter1.xhtml", "fun content");
    try epub.finish();
}
