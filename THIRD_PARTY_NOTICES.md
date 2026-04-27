# Third Party Notices

This file lists third-party materials used by markdown-preview.

## MIT Licensed Components

The following components are licensed under the MIT License. The MIT License
text below applies to each component in this section.

| Component              | Source                                                | Version or reference                       | Copyright notice                                      |
| ---------------------- | ----------------------------------------------------- | ------------------------------------------ | ----------------------------------------------------- |
| zig-tree-sitter        | https://github.com/tree-sitter/zig-tree-sitter        | `0cf58172e61f6fdd16f681cde42b4acb531a23db` | Copyright (c) 2024 tree-sitter contributors           |
| tree-sitter-c          | https://github.com/tree-sitter/tree-sitter-c          | `v0.24.1`                                  | Copyright (c) 2014 Max Brunsfeld                      |
| tree-sitter-rust       | https://github.com/tree-sitter/tree-sitter-rust       | `v0.24.2`                                  | Copyright (c) 2017 Maxim Sokolov                      |
| tree-sitter-go         | https://github.com/tree-sitter/tree-sitter-go         | `v0.25.0`                                  | Copyright (c) 2014 Max Brunsfeld                      |
| tree-sitter-python     | https://github.com/tree-sitter/tree-sitter-python     | `v0.25.0`                                  | Copyright (c) 2016 Max Brunsfeld                      |
| tree-sitter-javascript | https://github.com/tree-sitter/tree-sitter-javascript | `v0.25.0`                                  | Copyright (c) 2014 Max Brunsfeld                      |
| tree-sitter-bash       | https://github.com/tree-sitter/tree-sitter-bash       | `v0.25.1`                                  | Copyright (c) 2017 Max Brunsfeld                      |
| tree-sitter-cpp        | https://github.com/tree-sitter/tree-sitter-cpp        | `v0.23.4`                                  | Copyright (c) 2014 Max Brunsfeld                      |
| tree-sitter-typescript | https://github.com/tree-sitter/tree-sitter-typescript | `v0.23.2`                                  | Copyright (c) 2017 Max Brunsfeld                      |
| tree-sitter-html       | https://github.com/tree-sitter/tree-sitter-html       | `v0.23.2`                                  | Copyright (c) 2014 Max Brunsfeld                      |
| tree-sitter-css        | https://github.com/tree-sitter/tree-sitter-css        | `v0.23.2`                                  | Copyright (c) 2018 Max Brunsfeld                      |
| tree-sitter-json       | https://github.com/tree-sitter/tree-sitter-json       | `v0.24.8`                                  | Copyright (c) 2014 Max Brunsfeld                      |
| tree-sitter-zig        | https://github.com/kohdice/tree-sitter-zig            | `6c2f4f90cab7c72ec27d9dd19361649cc59f41c2` | Copyright (c) 2024 Amaan Qureshi <amaanq12@gmail.com> |
| Solarized              | https://github.com/altercation/solarized              | `master` palette values                    | Copyright (c) 2011 Ethan Schoonover                   |

### MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## Unicode Data

This project includes generated tables derived from Unicode data:

- `src/parse/unicode_case_fold_data.zig` records that it was generated from
  Python Unicode casefold data for Unicode 15.0.0.
- `src/mermaid/unicode_letter.zig` records that it was generated from Unicode
  16.0 `UnicodeData.txt`.

Unicode data files are licensed under the Unicode License v3.

Sources:

- https://www.unicode.org/license.txt
- https://www.unicode.org/Public/15.0.0/ucd/CaseFolding.txt
- https://www.unicode.org/Public/16.0.0/ucd/UnicodeData.txt

### Unicode License v3 Copyright and Permission Notice

UNICODE LICENSE V3 COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY DOWNLOADING,
INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR SOFTWARE, YOU
UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE TERMS AND
CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT DOWNLOAD, INSTALL,
COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a copy
of data files and any associated documentation (the "Data Files") or software
and any associated documentation (the "Software") to deal in the Data Files
or Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, and/or sell copies of the Data
Files or Software, and to permit persons to whom the Data Files or Software
are furnished to do so, provided that either (a) this copyright and permission
notice appear with all copies of the Data Files or Software, or (b) this
copyright and permission notice appear in associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE BE
LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES, OR
ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER
IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT
OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA FILES OR
SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall not
be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written authorization
of the copyright holder.
