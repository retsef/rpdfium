# frozen_string_literal: true

module Rpdfium
  # Albero di bookmark (outline) del documento. Costruito ricorsivamente.
  class Outline
    attr_reader :title, :page_index, :children

    def initialize(title, page_index, children)
      @title      = title
      @page_index = page_index
      @children   = children
    end

    def self.from_document(document)
      first = Raw.FPDFBookmark_GetFirstChild(document.handle, FFI::Pointer::NULL)
      build_siblings(document, first)
    end

    def self.build_siblings(doc, bookmark_handle)
      result = []
      ptr = bookmark_handle
      until ptr.nil?
        title = Raw.read_utf16_string(:FPDFBookmark_GetTitle, ptr)
        dest  = Raw.FPDFBookmark_GetDest(doc.handle, ptr)
        idx   = dest.nil? ? nil : Raw.FPDFDest_GetDestPageIndex(doc.handle, dest)
        idx = nil if idx == -1
        children_handle = Raw.FPDFBookmark_GetFirstChild(doc.handle, ptr)
        children = build_siblings(doc, children_handle)
        result << new(title, idx, children)
        ptr = Raw.FPDFBookmark_GetNextSibling(doc.handle, ptr)
      end
      result
    end

    # Iteratore flat preorder: utile per generare un sommario lineare.
    def self.flatten(outline_tree, depth = 0, &block)
      outline_tree.each do |item|
        block.call(item, depth)
        flatten(item.children, depth + 1, &block)
      end
    end

    def to_h
      { title: @title, page: @page_index,
        children: @children.map(&:to_h) }
    end
  end
end
