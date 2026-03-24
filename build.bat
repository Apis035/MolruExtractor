@echo off
if "%1" == "1" (
    echo Building release...
    odin build . -out:MolruExtractor.exe -show-timings -o:speed -lto:thin -source-code-locations:filename
) else (
    echo Building fast version...
    odin build . -out:MolruExtractorFast.exe -show-timings -o:speed -lto:thin -source-code-locations:none -microarch:native -no-bounds-check -disable-assert -no-type-assert
)