# Blue Archive Molru Extractor

A tool to extract assets from Blue Archive Steam version.

[TSN Kozeki](https://github.com/Ascellayn/TSN_Kozeki) used as base reference for understanding Blue Archive's media catalog file structure.

## Usage

1. Download [MolruExtractor](https://github.com/Apis035/MolruExtractor/releases/latest).
2. Move the downloaded executable into Blue Archive folder.
3. Run `MolruExtractor.exe`, wait for it to finish.
4. Extracted file can be found in `MolruExtract` folder.

## Feature comparison

| MolruExtractor | Kozeki |
| - | - |
| ✅ Native binary                                          | ➖ Requires Python to run |
| ✅ Run on any OS (manual compiling)                       | ✅ Run on any OS |
| ✅ No additional dependencies                             | ➖ Needs installing TSN Abstractor separately |
| ✅ Having a release as accessibility (for non-tech users) | ➖ Download/clone repository to use |
| ✅ Single executable                                      | ➖ Multiple files with its dependencies |
| ✅ Selective extraction<br>Can choose to skip extracting BGM, voice, or images. (See options with `-?` flag) | ❌ Cannot skip extracting specific files |
| ✅ Extract with file name                                 | ✅ Extract with file name (requires cache) |
| ✅ Fast caching process                                   | ❌ Takes forever to create cache (on Windows)<br>Can use the cache provied by the author instead, but needs to wait for the author to update cache for every game update. |
| ✅ Does not need to save cached catalog data              | ❌ Needs saved cache file for faster extraction process |
| ❌ No repacking feature planned                           | ✅ Plans to have repacking feature |
| ➖ Unsafe extraction algorithm                            | ✅ Uses regex to validate files to be extracted |

## Performance comparison

Measured by running both program 3 times. Best time is picked. MolruExtractor run with `-q` flag, Kozeki run with `--limit-logs` flag.

|   | Creating cache | Extracting | Memory usage |
| - | - | - | - | 
| MolruExtractor | 0.04s                                 | 32s   | 300-460 MB, constant (uses arena memory) |
| Kozeki         | ??? (stopped measuring after 3 hours) | 1m40s | 20-400 MB, up and down |

### Even more faster?

You can get even more performance by building MolruExtractor locally. This will create an executable optimized for your CPU, also disables extra safety checking for faster procesing.

1. Have [Odin](https://odin-lang.org/) installed on your system.
2. Clone this repository.
3. Run `build.bat`, this creates `MolruExtractorFast.exe`.
4. Move generated executable to Blue Archive folder.
5. Run. Optionally run with `-q` flag to disable logging (Significantly improve performance).

### License

MIT License
