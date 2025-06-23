# DAVbooru

DAVbooru is a simple danbooru-style imageboard for all your private media available over WebDAV.

## Installation

1. Create a new account for DAVbooru on your WebDAV-compatible cloud storage provider.
2. Share all necassary media with the DAVbooru user.
- Make sure the media will be available on the same path as the end user!
3. Configure whitelist and blacklist.
  - Create `whitelist.davbooru` and `blacklist.davbooru` in the same directory as the executable.
  - Specify the paths you want to index over WebDAV in the whitelist, and any phrases you want to exclude from indexing in the blacklist, one entry per line, no special syntax.
4. Launch DAVbooru and give it the correct credentials.

## Usage

Basic command:
```
davbooru -u <username or email> -p <password> --url <url of the WebDAV server>
```
For more details run `davbooru --help`.
