require 'rdoc/markup/formatter'
require 'rdoc/markup/inline'

require 'cgi'
require 'strscan'

##
# Outputs RDoc markup as HTML

class RDoc::Markup::ToHtml < RDoc::Markup::Formatter

  ##
  # Maps RDoc::Markup::Parser::LIST_TOKENS types to HTML tags

  LIST_TYPE_TO_HTML = {
    :BULLET => ['<ul>', '</ul>'],
    :LABEL  => ['<dl>', '</dl>'],
    :LALPHA => ['<ol style="display: lower-alpha">', '</ol>'],
    :NOTE   => ['<table class="rdoc-list">', '</table>'],
    :NUMBER => ['<ol>', '</ol>'],
    :UALPHA => ['<ol style="display: upper-alpha">', '</ol>'],
  }

  attr_reader :res # :nodoc:
  attr_reader :in_list_entry # :nodoc:
  attr_reader :list # :nodoc:

  ##
  # Converts a target url to one that is relative to a given path

  def self.gen_relative_url(path, target)
    from        = File.dirname path
    to, to_file = File.split target

    from = from.split "/"
    to   = to.split "/"

    from.delete '.'
    to.delete '.'

    while from.size > 0 and to.size > 0 and from[0] == to[0] do
      from.shift
      to.shift
    end

    from.fill ".."
    from.concat to
    from << to_file
    File.join(*from)
  end

  ##
  # Creates a new formatter that will output HTML

  def initialize
    super

    @th = nil
    @in_list_entry = nil
    @list = nil

    # external hyperlinks
    @markup.add_special(/((link:|https?:|mailto:|ftp:|www\.)\S+\w)/, :HYPERLINK)

    # and links of the form  <text>[<url>]
    @markup.add_special(/(((\{.*?\})|\b\S+?)\[\S+?\.\S+?\])/, :TIDYLINK)

    init_tags
  end

  ##
  # Maps attributes to HTML tags

  def init_tags
    add_tag :BOLD, "<b>",  "</b>"
    add_tag :TT,   "<tt>", "</tt>"
    add_tag :EM,   "<em>", "</em>"
  end

  ##
  # Generate a hyperlink for url, labeled with text. Handle the
  # special cases for img: and link: described under handle_special_HYPERLINK

  def gen_url(url, text)
    if url =~ /([A-Za-z]+):(.*)/ then
      type = $1
      path = $2
    else
      type = "http"
      path = url
      url  = "http://#{url}"
    end

    if type == "link" then
      url = if path[0, 1] == '#' then # is this meaningful?
              path
            else
              self.class.gen_relative_url @from_path, path
            end
    end

    if (type == "http" or type == "link") and
       url =~ /\.(gif|png|jpg|jpeg|bmp)$/ then
      "<img src=\"#{url}\" />"
    else
      "<a href=\"#{url}\">#{text.sub(%r{^#{type}:/*}, '')}</a>"
    end
  end

  # :section: Special handling

  ##
  # And we're invoked with a potential external hyperlink. <tt>mailto:</tt>
  # just gets inserted. <tt>http:</tt> links are checked to see if they
  # reference an image. If so, that image gets inserted using an
  # <tt><img></tt> tag. Otherwise a conventional <tt><a href></tt> is used.
  # We also support a special type of hyperlink, <tt>link:</tt>, which is a
  # reference to a local file whose path is relative to the --op directory.

  def handle_special_HYPERLINK(special)
    url = special.text
    gen_url url, url
  end

  ##
  # Here's a hypedlink where the label is different to the URL
  #  <label>[url] or {long label}[url]

  def handle_special_TIDYLINK(special)
    text = special.text

    return text unless text =~ /\{(.*?)\}\[(.*?)\]/ or text =~ /(\S+)\[(.*?)\]/

    label = $1
    url   = $2
    gen_url url, label
  end

  # :section: Utilities

  ##
  # This is a higher speed (if messier) version of wrap

  def wrap(txt, line_len = 76)
    res = []
    sp = 0
    ep = txt.length

    while sp < ep
      # scan back for a space
      p = sp + line_len - 1
      if p >= ep
        p = ep
      else
        while p > sp and txt[p] != ?\s
          p -= 1
        end
        if p <= sp
          p = sp + line_len
          while p < ep and txt[p] != ?\s
            p += 1
          end
        end
      end
      res << txt[sp...p] << "\n"
      sp = p
      sp += 1 while sp < ep and txt[sp] == ?\s
    end

    res.join.strip
  end

  # :section: Visitor

  def start_accepting
    @res = []
    @in_list_entry = []
    @list = []
  end

  def end_accepting
    @res.join
  end

  def accept_paragraph(paragraph)
    @res << "\n<p>"
    @res << wrap(to_html(paragraph.text))
    @res << "</p>\n"
  end

  def accept_verbatim(verbatim)
    @res << "\n<pre>"
    @res << CGI.escapeHTML(verbatim.text.rstrip)
    @res << "</pre>\n"
  end

  def accept_rule(rule)
    size = rule.weight
    size = 10 if size > 10
    @res << "<hr style=\"height: #{size}px\">\n"
  end

  def accept_list_start(list)
    @list << list.type
    @res << html_list_name(list.type, true)
    @in_list_entry.push false
  end

  def accept_list_end(list)
    @list.pop
    if tag = @in_list_entry.pop
      @res << tag
    end
    @res << html_list_name(list.type, false) << "\n"
  end

  def accept_list_item_start(list_item)
    if tag = @in_list_entry.last
      @res << tag
    end

    @res << list_item_start(list_item, @list.last)
  end

  def accept_list_item_end(list_item)
    @in_list_entry[-1] = list_end_for(@list.last)
  end

  def accept_blank_line(blank_line)
    # @res << annotate("<p />") << "\n"
  end

  def accept_heading(heading)
    @res << "\n<h#{heading.level}>"
    @res << to_html(heading.text)
    @res << "</h#{heading.level}>\n"
  end

  def accept_raw raw
    @res << raw.parts.join("\n")
  end

  private

  ##
  # Converts string +item+

  def convert_string(item)
    CGI.escapeHTML item
  end

  ##
  # Determins the HTML list element for +list_type+ and +open_tag+

  def html_list_name(list_type, open_tag)
    tags = LIST_TYPE_TO_HTML[list_type]
    raise RDoc::Error, "Invalid list type: #{list_type.inspect}" unless tags
    tags[open_tag ? 0 : 1]
  end

  ##
  # Starts a list item

  def list_item_start(list_item, list_type)
    case list_type
    when :BULLET, :LALPHA, :NUMBER, :UALPHA then
      "<li>"
    when :LABEL then
      "<dt>" << to_html(list_item.label) << "</dt>\n<dd>"
    when :NOTE then
        '<tr><td class="rdoc-term"><p>' + to_html(list_item.label) + "</p></td>\n<td>"
    else
      raise RDoc::Error, "Invalid list type: #{list_type.inspect}"
    end
  end

  ##
  # Ends a list item

  def list_end_for(list_type)
    case list_type
    when :BULLET, :LALPHA, :NUMBER, :UALPHA then
      "</li>"
    when :LABEL then
      "</dd>"
    when :NOTE then
      "</td></tr>"
    else
      raise RDoc::Error, "Invalid list type: #{list_type.inspect}"
    end
  end

  ##
  # Converts ampersand, dashes, ellipsis, quotes, copyright and registered
  # trademark symbols to HTML escaped Unicode.
  #--
  # TODO transcode when the output encoding is not UTF-8

  def to_html(text)
    html = ''
    s = StringScanner.new convert_flow @am.flow text
    insquotes = false
    indquotes = false
    after_word = nil

#p :start => s

    until s.eos? do
      case
      # skip HTML tags
      when s.scan(/<[^>]+\/?s*>/)
#p "tag: #{s.matched}"
        html << s.matched
        # skip <tt>...</tt> sections
        if s.matched == '<tt>'
          if s.scan(/.*?<\/tt>/)
            html << s.matched.gsub('\\\\', '\\')
          else
            # TODO signal non-paired tags
            html << s.rest
            break
          end
        end
      # escape of \ not handled by RDoc::Markup::ToHtmlCrossref
      # \<non space> => <non space> (markup spec)
      when s.scan(/\\(\S)/)
#p "backslashes: #{s.matched}"
        html << s[1]
        after_word = nil
      # ... => ellipses (.... => . + ellipses)
      when s.scan(/\.\.\.(\.?)/)
#p "ellipses: #{s.matched}"
        html << s[1] << '&#8230;'
        after_word = nil
      # (c) => copyright
      when s.scan(/\(c\)/)
#p "copyright: #{s.matched}"
        html << '&#169;'
        after_word = nil
      # (r) => registered trademark
      when s.scan(/\(r\)/)
#p "trademark: #{s.matched}"
        html << '&#174;'
        after_word = nil
      # --- or -- => em-dash
      when s.scan(/---?/)
#p "em-dash: #{s.matched}"
        html << '&#8212;'
        after_word = nil
      # double quotes
      when s.scan(/&quot;/)  #"
#p "dquotes: #{s.matched}"
        html << (indquotes ? '&#8221;' : '&#8220;')
        indquotes = !indquotes
        after_word = nil
      # faked double quotes
      when s.scan(/``/)
#p "dquotes: #{s.matched}"
        html << '&#8220;' # opening
        after_word = nil
      when s.scan(/''/)
#p "dquotes: #{s.matched}"
        html << '&#8221;' # closing
        after_word = nil
      # single quotes
      when s.scan(/'/) #'
#p "squotes: #{s.matched}"
        if insquotes
          html << '&#8217;' # closing
          insquotes = false
        else
          # Mary's dog, my parents' house: do not start paired quotes
          if after_word
            html << '&#8217;' # closing
          else
            html << '&#8216;' # opening
            insquotes = true
          end
        end
        after_word = nil
      # none of the above: advance to the next potentially significant character
      else
        match = s.scan(/.+?(?=[-<\\\.\("'`&])/) #"
        if match
#p "next: #{match}"
          html << match
          after_word = match =~ /\w$/
        else
#p "rest: #{s.rest}"
          html << s.rest
          break
        end
      end
    end

    html
  end

end

