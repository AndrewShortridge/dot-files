; Snacks.nvim image query for markdown_inline.
; Matches standard markdown images: ![alt](src)
; and wikilink-style images: ![[image.png]]
;
; Filter: require a file extension (dot + word chars at end) to exclude
; Obsidian block refs (![[^blk-xxx]]) and heading refs (![[#Heading]])
; that treesitter parses as (image) nodes via the shortcut_link branch.

(image
  [
    (link_destination) @image.src
    (image_description (shortcut_link ((link_text) @image.src)))
  ]
    (#gsub! @image.src "|.*" "") ; remove wikilink image options
    (#gsub! @image.src "^<" "") ; remove bracket link
    (#gsub! @image.src ">$" "")
    (#lua-match? @image.src "%.%w+$")
  ) @image
