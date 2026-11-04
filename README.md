# Buckets

A native macOS app for browsing and managing Cloudflare R2 and other S3-compatible buckets.

- Save as many connections as you like, each with its own credentials (secrets live in the Keychain)
- Finder-style list and icon views, path bar, inspector, Quick Look
- Drag and drop files and folders to upload (multipart for large files)
- Create folders, rename, delete, download, and edit text files in place

## Requirements
macOS 15 or later, Xcode 16 or later.

## Build
```sh
Scripts/build-app.sh        # → build/Buckets.app
open build/Buckets.app
```
For development, `open Package.swift` in Xcode and run the `Buckets` scheme, or `swift run`.
