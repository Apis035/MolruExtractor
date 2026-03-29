#+vet explicit-allocators
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

// --------------------------------------------------------

AssertError :: #force_inline proc(err: $E, msg: string, loc := #caller_location) {
	if err == nil do return
	panic(fmt.tprint(msg, ": ", err, sep=""), loc=loc)
}

AssertReturnValue :: #force_inline proc(v: $T, err: $E, msg: string, loc := #caller_location) -> T {
	if err == nil do return v
	panic(fmt.tprint(msg, ": ", err, sep=""), loc=loc)
}

Assert :: proc {
	AssertError,
	AssertReturnValue,
}

// --------------------------------------------------------

measureTime: time.Time

BeginMeasure :: proc() {
	measureTime = time.now()
}

EndMeasure :: proc(msg: string) {
	totalTime := time.duration_seconds(time.since(measureTime))
	fmt.printfln("%s done in %.3f seconds", msg, totalTime)
}

// --------------------------------------------------------

FolderId :: enum u8 {
	Root     = 0x01,
	Preload  = 0x02,
	GameData = 0x03,
}

@(rodata)
FolderPath := [FolderId]string {
	.Root     = "BlueArchive_Data/StreamingAssets/",
	.Preload  = "BlueArchive_Data/StreamingAssets/PUB/Resource/Preload/MediaResources/",
	.GameData = "BlueArchive_Data/StreamingAssets/PUB/Resource/GameData/MediaResources/",
}

// --------------------------------------------------------

CATALOG_FILE :: "BlueArchive_Data/StreamingAssets/PUB/Resource/Catalog/MediaResources/MediaCatalog.bytes"

Catalog      :: map[string]CatalogEntry
CatalogEntry :: [dynamic]string

ParseCatalog :: proc(data: []byte) -> (catalog: Catalog) {
	skip: bool
	data := data[9:]
	for len(data) > 12 {
		length := data[0]
		data    = data[4:]

		skip = !skip
		defer data = skip ? data[length+5:] : data[length+12:]
		if skip do continue

		value := string(data[:length])
		id    := data[length]

		if skipImage && strings.contains(value, "UIs") do continue
		if skipBgm   && strings.contains(value, "BGM") do continue
		if skipVoice && strings.contains(value, "VOC") do continue

		dir, file := os.split_path(value)
		key := Assert(os.join_path({FolderPath[FolderId(id)], dir}, context.allocator), "Fail joining path")

		if catalog[key] == nil {
			catalog[key] = make(CatalogEntry, context.allocator)
		}
		append(&catalog[key], file)
	}
	return catalog
}

DeleteCatalog :: proc(catalog: Catalog) {
	for key, entry in catalog {
		delete(key, context.allocator)
		delete(entry)
	}
	delete(catalog)
}

PrintCatalog :: proc(catalog: Catalog) {
	for key, entry in catalog {
		fmt.println(key, "{")
		for value in entry {
			fmt.println("    ", value)
		}
		fmt.println("}")
	}
}

CACHED_CATALOG_FILE :: "catalogdata.json"

SaveCatalog :: proc(catalog: Catalog) {
	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)

	for key, entry in catalog {
		fmt.sbprintfln(&b, "%s: [", key,)
		for value in entry {
			fmt.sbprintfln(&b, "\t\"%s\"", value)
		}
		fmt.sbprintln(&b, "]")
	}

	Assert(os.write_entire_file(CACHED_CATALOG_FILE, strings.to_string(b)), "Fail to save cached catalog")
}

// --------------------------------------------------------

BytesEqual :: proc(data: []byte, b: string) -> bool {
	return string(data[:len(b)]) == b
}

// Skip several bytes for faster searching. 159 breaks.
SKIP_LENIENCY :: 158 * mem.Byte

FindBytes :: proc(data: []byte, b: string, offset := 0) -> (int, bool) {
	skip := SKIP_LENIENCY + len(b)
	data := data[skip:]
	for _, i in data {
		if i + len(b) > len(data) do break
		if BytesEqual(data[i:], b) {
			return i + skip + offset, true
		}
	}
	return -1, false
}

// --------------------------------------------------------

Format :: enum {
	Unknown,
	PNG,
	JPG,
	OGG,
}

Found :: struct {
	begin, end: int,
}

Iterator :: struct {
	data: []byte,
	next: int,
	type: Format,
	last: bool,
}

CreateIterator :: proc(data: []byte) -> (it: Iterator) {
	it = {data = data, next = 53}
	GetData(&it) // identify data
	return
}

/*
`GetData` does a very quick check without validating the data further.

A molru file will be marked as a container of a certain format by checking
what is stored on its first entry. After that, the next scan will look only
for that file format.

Start and end of a file is scanned by the format header marker.
For PNG, if there is no next header found, then IEND marker plus 4 bytes will
be scanned. For JPEG, the 2 bytes of end and start of a JPEG used for scanning,
this simplifies the scanning for shitty JPEG structure. For OGG, it's data is
split across multiple header, the start and end is marked by the 6th byte in
the header, then calculate the length from the last header.

This would break if Nexon mix different file format in one molru file.

I write this comment so future me can understand what code did I wrote here. 🙏
*/
GetData :: proc(it: ^Iterator) -> (found: Found, ok: bool) {
	if it.last do return

	found.begin  = it.next
	found.end    = it.next

	end: int
	scan := it.data[it.next:]
	defer it.next = found.end

	switch it.type {
	case .Unknown:
		switch {
			case BytesEqual(scan, "\x89PNG"):      it.type  = .PNG
			case BytesEqual(scan, "\xFF\xD8"):     it.type  = .JPG
			case BytesEqual(scan, "OggS\x00\x02"): it.type  = .OGG
			case: panic("Unknown molru data file format")
		}

	case .PNG:
		end, ok = FindBytes(scan, "\x89PNG")
		if !ok do end, it.last = FindBytes(scan, "IEND", 8)
		found.end += end

	case .JPG:
		end, ok = FindBytes(scan, "\xFF\xD9\xFF\xD8", 2)
		if !ok do end, it.last = FindBytes(scan, "\xFF\xD9", 2)
		found.end += end

	case .OGG:
		length, ok := CalcOggLength(scan)
		if !ok do return {}, false
		found.end += length
	}

	return found, true
}

CalcOggLength :: proc(data: []byte) -> (length: int, ok: bool) {
	i         := FindBytes(data, "OggS\x00\x04") or_return
	pageCount := int(data[i+26])
	pages     := data[i+27 : i+27+pageCount]
	pagesSum: int
	for j in pages {
		pagesSum += int(j)
	}
	return i + 26 + 1 + pageCount + pagesSum, true
}

// --------------------------------------------------------

EXTRACT_DIRECTORY :: "MolruExtract"

Extract :: proc(catalog: Catalog) {
	memBuffer := make([]byte, 512 * mem.Megabyte, context.allocator)
	defer delete(memBuffer, context.allocator)

	arena: mem.Arena
	mem.arena_init(&arena, memBuffer)
	fileBuffer := mem.arena_allocator(&arena)

	for key, entry in catalog {
		defer free_all(context.temp_allocator)

		if verbose do fmt.println(key)

		molruPath := strings.concatenate({key, ".molru"}, context.temp_allocator)
		os.exists(molruPath) or_continue

		extractDir := Assert(os.join_path({EXTRACT_DIRECTORY, key}, context.temp_allocator), "Fail to join path")
		os.make_directory_all(extractDir)

		molruFile := Assert(os.read_entire_file(molruPath, fileBuffer), "Fail to read molru file")
		defer free_all(fileBuffer)

		i: int
		it := CreateIterator(molruFile)
		for found in GetData(&it) {
			name := i < len(entry) ? entry[i] : fmt.tprintf("unknown_%8x.%v", found.begin, it.type)
			if verbose do fmt.printfln("    [%v: %8x-%8x] %s", it.type, found.begin, found.end, name)
			extractFile := Assert(os.join_path({extractDir, name}, context.temp_allocator), "Fail to join path")
			Assert(os.write_entire_file(extractFile, molruFile[found.begin:found.end]), "Fail to save data")
			i += 1
		}
		assert(i == len(entry))
	}
}

// --------------------------------------------------------

verbose   := true
skipBgm   := false
skipVoice := false
skipImage := false
saveCache := false

main :: proc() {
	// For quick testing
	// os.change_directory("D:/SteamLibrary/steamapps/common/BlueArchive")

	fmt.println("---------------------------------")
	fmt.println("MolruExtractor v1.1 - 2026.04")
	fmt.println("github.com/Apis035/MolruExtractor")
	fmt.println("---------------------------------")

	for arg in os.args do switch arg {
	case "-nb", "-no-bgm":     skipBgm   = true
	case "-nv", "-no-voice":   skipVoice = true
	case "-ni", "-no-image":   skipImage = true
	case "-s",  "-save-cache": saveCache = true
	case "-q",  "-quiet":      verbose   = false
	case "/?", "-?", "-h", "-help":
		fmt.println("Usage:", os.args[0], "[option]")
		fmt.println("Options:")
		fmt.println("  -nb, -no-bgm        Skip extracting BGM.")
		fmt.println("  -nv, -no-voice      Skip extracting voice.")
		fmt.println("  -ni, -no-image      Skip extracting image.")
		fmt.println("  -s,  -save-cache    Save cached catalog data")
		fmt.println("  -q,  -quiet         Don't print processing logs. Improves extracting speed.")
		return
	}

	fmt.println("Getting catalog data...")
	rawCatalog := Assert(os.read_entire_file(CATALOG_FILE, context.allocator), "Fail to open catalog file")
	defer delete(rawCatalog, context.allocator)

	fmt.println("Parsing catalog data...")
	BeginMeasure()
	catalog := ParseCatalog(rawCatalog)
	EndMeasure("Parsing")
	defer DeleteCatalog(catalog)

	// fmt.println("Catalog data:")
	// PrintCatalog(catalog)

	if saveCache {
		fmt.println("Saving catalog file...")
		SaveCatalog(catalog)
	}

	fmt.println("Extracting files...")
	BeginMeasure()
	Extract(catalog)
	EndMeasure("Extracting")
}
