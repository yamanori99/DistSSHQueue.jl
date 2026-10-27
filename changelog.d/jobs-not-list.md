category: planned

- A `jobs` value that is not a list will be rejected on read. 0.9.x leaves
  the file on disk. `status` warns once. A write already stops with `Error:`
  and does not replace the file.
