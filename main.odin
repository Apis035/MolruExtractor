#+vet explicit-allocators
package main

import "base:runtime"
import "core:encoding/json"
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

	for {
		length := data[0]
		data = data[4:]
		if skip = !skip; skip {
			data = data[length+5:]
		} else {
			if int(length+12) >= len(data) do break
			defer data = data[length+12:]

			dir, file := os.split_path(string(data[:length]))

			if skipImage && strings.contains(dir, "UIs") do continue
			if skipBgm   && strings.contains(dir, "BGM") do continue
			if skipVoice && (strings.contains(dir, "VOC_JP") || strings.contains(dir, "VOC_KR")) do continue

			id  := FolderId(data[length])
			key := Assert(os.join_path({FolderPath[id], dir}, context.allocator), "Fail joining path")

			if catalog[key] == nil {
				catalog[key] = make(CatalogEntry, context.allocator)
			}
			append(&catalog[key], file)
		}
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
	catalogData := Assert(json.marshal(catalog, {spec = .SJSON, pretty = true}, context.allocator), "Json marshall failed")
	defer delete(catalogData, context.allocator)
	Assert(os.write_entire_file(CACHED_CATALOG_FILE, catalogData), "Fail to save cached catalog")
}

// --------------------------------------------------------

BytesEqual :: proc(data: []byte, b: string) -> bool {
	return string(data[:len(b)]) == b
}

FindBytes :: proc(data: []byte, b: string) -> int {
	for _, i in data {
		if i + len(b) > len(data) do break

		if BytesEqual(data[i:], b) {
			return i
		}
	}
	return -1
}

// --------------------------------------------------------

Format :: enum {
	Unknown,
	PNG,
	JPG,
	OGG,
}

Found :: struct {
	format: Format,
	begin, end: int,
}

Iterator :: struct {
	data: []byte,
	next: int,
	type: Format,
	last: bool,
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

	if it.type == .Unknown {
		it.next = 53
		it.type =
			BytesEqual(it.data[53:], "\x89PNG")      ? .PNG :
			BytesEqual(it.data[53:], "\xFF\xD8")     ? .JPG :
			BytesEqual(it.data[53:], "OggS\x00\x02") ? .OGG : .Unknown
	}

    // TODO: Clean those repetetive returns

	switch it.type {
    case .Unknown:
        panic("Unknown molru file format")

	case .PNG:
		end := FindBytes(it.data[it.next+4:], "\x89PNG")
		if end == -1 {
			end     = FindBytes(it.data[it.next+4:], "IEND") + 8
			it.last = true
		}
		found.format = .PNG
		found.begin  = it.next
		found.end    = it.next + end
		it.next     += end + 4
		return found, true

	case .JPG:
		end := FindBytes(it.data[it.next+2:], "\xFF\xD9\xFF\xD8")
		if end == -1 {
			end     = FindBytes(it.data[it.next+2:], "\xFF\xD9")
			it.last = true
		}
		end         += 2 + 2
		found.format = .JPG
		found.begin  = it.next
		found.end    = it.next + end
		it.next     += end
		return found, true

	case .OGG:
		length := CalcOggLength(it.data[it.next+4:])
		if length == -1 {
			return {}, false
		}
		length      += 4
		found.format = .OGG
		found.begin  = it.next
		found.end    = it.next + length
		it.next     += length
		return found, true
	}

	return
}

CalcOggLength :: proc(data: []byte) -> int {
	i := FindBytes(data, "OggS\x00\x04")
	if i == -1 {
		return -1
	}
	pageCount := int(data[i+26])
	pages     := data[i+27 : i+27+pageCount]
	pagesSum: int
	for j in pages {
		pagesSum += int(j)
	}
	return i + 26 + 1 + pageCount + pagesSum
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
		if verbose do fmt.println(key)

		molruPath := strings.concatenate({key, ".molru"}, context.temp_allocator)
		os.exists(molruPath) or_continue

		extractDir := Assert(os.join_path({EXTRACT_DIRECTORY, key}, context.temp_allocator), "Fail to join path")
		os.make_directory_all(extractDir)

		molruFile := Assert(os.read_entire_file(molruPath, fileBuffer), "Fail to read molru file")
		defer free_all(fileBuffer)

		i: int
		it := Iterator{data=molruFile}
		for found in GetData(&it) {
			name := i < len(entry) ? entry[i] : fmt.tprintf("unknown_%8x.%v", found.begin, found.format)

			if verbose do fmt.printfln("    [%v: %8x-%8x] %s", found.format, found.begin, found.end, name)

			extractFile := Assert(os.join_path({extractDir, name}, context.temp_allocator), "Fail to join path")
			Assert(os.write_entire_file(extractFile, molruFile[found.begin:found.end]), "Fail to save data")

			i += 1
		}
		assert(i == len(entry))

		free_all(context.temp_allocator)
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
	fmt.println("MolruExtractor v1.0 - 2026.04")
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
	defer DeleteCatalog(catalog)
	EndMeasure("Parsing")

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
