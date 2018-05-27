require 'notmuch'
require 'rubygems'
require 'tempfile'
require 'socket'
require 'mail'
require 'mail-gpg'
require 'rack/mime'

$db_name = nil
$all_emails = []
$email = $email_name = $email_address = nil
$exclude_tags = []
$searches = []

def get_config_item(item)
  result = ''
  cfg = '--config=' + File.expand_path(VIM::evaluate('g:notmuch_config_file'))
  IO.popen(['notmuch', cfg, 'config', 'get', item]) { |out|
    result = out.read
  }
  return result.rstrip
end

def get_config
  $db_name = get_config_item('database.path')
  $email_name = get_config_item('user.name')
  $email_address = get_config_item('user.primary_email')
  $secondary_email_addresses = get_config_item('user.primary_email')
  $email = '%s <%s>' % [$email_name, $email_address]
  other_emails = get_config_item('user.other_email')
  $all_emails = other_emails.split("\n")
  # Add the primary to this too as we use it for checking
  # addresses when doing a reply
  $all_emails.unshift($email_address)
  ignore_tags = get_config_item('search.exclude_tags')
  $exclude_tags = ignore_tags.split("\n")
end

def vim_puts(s)
  VIM::command("echo '#{s.to_s}'")
end

def vim_err(s)
  VIM::command("echohl ErrorMsg")
  VIM::command("echomsg '#{s.to_s}'")
  VIM::command("echohl NONE")
end

def author_filter(a)
  a.strip!
  a.gsub!(/[\.@].*/, '')
  a.gsub!(/^ext /, '')
  a.gsub!(/ \(.*\)/, '')
  a
end

def get_thread_id
  n = $curbuf.line_number - 1
  return '' if n >= $curbuf.threads.count
  return 'thread:%s' % $curbuf.threads[n]
end

def get_message
  n = $curbuf.line_number
  return $curbuf.messages.find { |m| n >= m.start && n < m.end }
end

def get_cur_view
  if $cur_filter
    return "#{$curbuf.cur_thread} and (#{$cur_filter})"
  else
    return $curbuf.cur_thread
  end
end

def generate_message_id(hostname)
  timestamp = '%10.5f' % Time.now.to_f
  return "<#{timestamp}@#{hostname}>"
end

def is_our_address(address)
  $all_emails.each do |addy|
    if address.to_s.index(addy) != nil
      return addy
    end
  end
  return nil
end

def open_reply(orig)
  reply = orig.reply do |m|
    m.cc = []
    email = $email
    # Use hashes for email addresses so we can eliminate duplicates.
    cc = Hash.new
    if orig[:cc]
      orig[:cc].each do |o|
        cc[o.address] = o
      end
    end
    if orig[:to]
      orig[:to].each do |o|
        cc[o.address] = o
      end
    end
    if orig[:from]
      orig[:from].each do |o|
        if is_our_address(o.address)
          email = o
        end
      end
    end
    cc.each do |e_addr, addr|
      if is_our_address(e_addr)
        email = addr
      else
        m.cc << addr
      end
    end
    m.from = "#{email}"
    if m.to != m.from
      m.bcc = "#{email}"
    end
    m.charset = 'utf-8'
  end

  lines = []

  body_lines = []
  addr = Mail::Address.new(orig[:from].value)
  name = addr.name
  name = addr.local + '@' if name.nil? && !addr.local.nil?
  name = 'somebody' if name.nil?

  body_lines << '%s wrote:' % name
  part = orig.find_first_text
  part.convert.each_line do |l|
    body_lines << '> %s' % l.chomp
  end
  body_lines << ''
  body_lines << ''
  body_lines << ''

  reply.body = body_lines.join("\n")

  lines += reply.present.lines.map { |e| e.chomp }
  lines << ''

  cur = lines.count - 1

  open_compose_helper(lines, cur)
end

def folders_render()
  $curbuf.render do |b|
    folders = VIM::evaluate('g:notmuch_folders')
    count_threads = VIM::evaluate('g:notmuch_folders_count_threads') == 1
    display_unread = VIM::evaluate('g:notmuch_folders_display_unread_count') == 1
    $searches.clear
    longest_name = 0
    folders.each do |name, search|
      if name.length > longest_name
        longest_name = name.length
      end
    end
    folders.each do |name, search|
      q = $curbuf.query(search)
      $exclude_tags.each { |t|
        q.add_tag_exclude(t)
      }
      $searches << search
      count = count_threads ? q.count_threads : q.count_messages
      if name == ''
        b << ''
      elsif display_unread
        u = $curbuf.query('(%s) and tag:unread' % [search])
        $exclude_tags.each { |t|
          u.add_tag_exclude(t)
        }
        ucount = count_threads ? u.count_threads : u.count_messages
        b << "%9d (%3d) %-#{longest_name + 1}s (%s)" % [count, ucount, name, search]
      else
        b << "%9d %-#{longest_name + 1}s (%s)" % [count, name, search]
      end
    end
  end
end

def search_render(search)
  date_fmt = VIM::evaluate('g:notmuch_search_date_format')
  q = $curbuf.query(search)
  q.sort = Notmuch::SORT_NEWEST_FIRST
  $exclude_tags.each { |t|
    q.add_tag_exclude(t)
  }
  $curbuf.threads.clear
  t = q.search_threads

  $render = $curbuf.render_staged(t) do |b, items|
    items.each do |e|
      authors = e.authors.to_utf8.split(/[,|]/).map { |a| author_filter(a) }.join(',')
      date = Time.at(e.newest_date).strftime(date_fmt)
      subject = e.messages.first['subject']
      subject = Mail::Field.new('subject', subject).to_s
      b << '%-12s %3s %-20.20s | %s (%s)' % [date, e.matched_messages, authors, subject, e.tags]
      $curbuf.threads << e.thread_id
    end
  end
end

def render()
  filetype = VIM::evaluate('&filetype')
  if filetype == 'notmuch-folders'
    folders_render()
  elsif filetype == 'notmuch-search'
    search_render($cur_search)
  end
end

def tag(filter, tags)
  if not filter.empty?
    $curbuf.do_write do |db|
      q = db.query(filter)
      q.search_messages.each do |e|
        e.freeze
        tags.split.each do |t|
          case t
          when /^-(.*)/
            e.remove_tag($1)
          when /^\+(.*)/
            e.add_tag($1)
          when /^([^\+^-].*)/
            e.add_tag($1)
          end
        end
        e.thaw
        e.tags_to_maildir_flags
      end
      q.destroy!
    end
  end
end

def compose_send(text, fname)
  # Generate proper mail to send
  nm = Mail.new(text.join("\n"))
  nm.charset = 'utf-8'
  attachment = nil
  hostname = nil
  files = []
  sign = VIM::evaluate('g:notmuch_gpg_sign') == 1
  encrypt = !(nm.header['Subject'].to_s =~ /(?:encrypt(?:ed)?|pgp|gpg)$/i).nil?
  nm.header.fields.each do |f|
    if f.name == 'Attach' and f.value.length > 0 and f.value !~ /^\s+/
      # We can't just do the attachment here because it screws up the
      # headers and makes our loop incorrect.
      files.push(f.value)
      attachment = f
    elsif f.name == 'From'
      hostname = f.value.split('@')[1].split('>')[0]
    end
  end
  nm.message_id = generate_message_id(hostname)

  files.each do |f|
    vim_puts("Attaching file #{f}")
    nm.add_file(File.expand_path(f))
  end

  if attachment
    # This deletes them all as it matches the key 'name' which is
    # 'Attach'.  We want to do this because we don't really want
    # those to be part of the header.
    nm.header.fields.delete(attachment)
  end

  del_method = VIM::evaluate('g:notmuch_sendmail_method').to_sym
  del_param = {
    :location => VIM::evaluate('g:notmuch_sendmail_location'),
    :arguments => VIM::evaluate('g:notmuch_sendmail_arguments')
  }

  vim_puts("Sending email via #{del_method}...")
  nm.delivery_method del_method, del_param
  nm.gpg encrypt: encrypt, sign: sign
  nm.deliver
  vim_puts('Delivery complete.')

  save_locally = VIM::evaluate('g:notmuch_save_sent_locally') == 1
  if save_locally
    File.write(fname, nm.to_s)
    local_mailbox = VIM::evaluate('g:notmuch_save_sent_mailbox')
    system("notmuch insert --create-folder --folder=#{local_mailbox} +sent -unread -inbox < #{fname}")
    File.delete(fname)
  end
end

def prev_message()
  r, c = $curwin.cursor
  n = $curbuf.line_number
  messages = $curbuf.messages
  i = messages.index { |m| n >= m.start && n < m.end }
  m = messages[i - 1] if i > 0
  if m
    fold = VIM::evaluate("foldclosed(#{m.start})")
    if fold > 0
      # If we are moving to a fold then we don't want to move
      # into the fold as it doesn't seem right once you open it.
      VIM::command("normal #{m.start}zt")
    else
      r = m.body_start + 1
      scrolloff = VIM::evaluate('&scrolloff')
      VIM::command("normal #{m.start + scrolloff}zt")
      $curwin.cursor = r + scrolloff, c
    end
  end
end

def next_message(matching_tag)
  r, c = $curwin.cursor
  n = $curbuf.line_number
  messages = $curbuf.messages
  i = messages.index { |m| n >= m.start && n < m.end }
  i = i + 1
  found_msg = nil
  while i < messages.length and found_msg == nil
    m = messages[i]
    if matching_tag.length > 0
      m.tags.each do |tag|
        if tag == matching_tag
          found_msg = m
          break
        end
      end
    else
      found_msg = m
      break
    end
    i = i + 1
  end

  if found_msg
    fold = VIM::evaluate("foldclosed(#{found_msg.start})")
    if fold > 0
      # If we are moving to a fold then we don't want to move
      # into the fold as it doesn't seem right once you open it.
      VIM::command("normal #{found_msg.start}zt")
    else
      r = found_msg.body_start + 1
      scrolloff = VIM::evaluate('&scrolloff')
      VIM::command("normal #{found_msg.start + scrolloff}zt")
      $curwin.cursor = r + scrolloff, c
    end
  end
end

def open_compose_helper(lines, cursor)
  dir = File.expand_path('~/.notmuch/compose')
  FileUtils.mkdir_p(dir)
  Tempfile.open(['nm-', '.mail'], dir) do |f|
    f.puts(lines)
    sig_file = File.expand_path('~/.signature')
    if File.exists?(sig_file)
      f.puts('--')
      f.write(File.read(sig_file))
    end
    f.flush
    VIM::command("call s:NewFileBuffer('compose', '#{f.path}')")
    VIM::command("call cursor(#{cursor}, 0)")
  end
end

def open_compose(to_email)
  lines = []
  lines << "From: #{$email}"
  lines << "To: #{to_email}"
  cursor = lines.count
  lines << 'Cc: '
  lines << "Bcc: #{$email}"
  lines << 'Subject: '
  lines << ''
  open_compose_helper(lines, cursor)
end

def view_magic(line, lineno, fold)
  # Also use enter to open folds.  After using 'enter' to get
  # all the way to here it feels very natural to want to use it
  # to open folds too.
  if fold > 0
    VIM::command('foldopen')
    scrolloff = VIM::evaluate('&scrolloff')
    vim_puts("Moving to #{lineno} + #{scrolloff} zt")
    # We use relative movement here because of the folds
    # within the messages (header folds).  If you use absolute movement the
    # cursor will get stuck in the fold.
    VIM::command("normal #{scrolloff}j")
    VIM::command('normal zt')
  else
    # Easiest to check for 'Part' types first..
    match = line.match(/^Part (\d*):/)
    if match and match.length == 2
      view_attachment(line)
    else
      VIM::command('call s:OpenUri()')
    end
  end
end

def format_filename(filename, suffix, mime_type)
  if not filename
    extension = Rack::Mime::MIME_TYPES.invert[mime_type]
    filename = "part-#{suffix}#{extension}"
  end
  filename.gsub!(/[^0-9A-Za-z.\-]/, '-')
  filename.gsub!(/--+/, '-')
  return filename
end

def parse_part(line)
  m = get_message
  # Part index: type/subtype (filename)
  match = line.match(/^Part (\d*): ([^\/]+)\/([^ ]+) \(([^)]+)\)/)
  if match and match.length == 5
    index = match[1].to_i - 1
    filename = match[4]
    part = m.mail.all_parts[index]
    return part, filename
  end
end

def extract_part(line)
  part, filename = parse_part(line)
  if part
    dir = VIM::evaluate('g:notmuch_attachment_dir')
    dir = File.expand_path(dir)
    Dir.mkdir(dir) unless Dir.exists?(dir)
    fullpath = File.expand_path("#{dir}/#{filename}")
    File.open(fullpath, 'w') do |f|
      f.write part.body.decoded
    end
    return fullpath
  end
end

def view_attachment(line)
  fullpath = extract_part(line)
  if fullpath
    vim_puts "Viewing attachment #{fullpath}"
    cmd = VIM::evaluate('g:notmuch_view_attachment')
    system(cmd, fullpath)
  else
    vim_puts 'No attachment on this line.'
  end
end

def open_uri(line, col)
  uris = URI.extract(line)
  wanted_uri = nil
  if uris.length == 1
    wanted_uri = uris[0]
  else
    uris.each do |uri|
      # Check to see the URI is at the present cursor location
      idx = line.index(uri)
      if col >= idx and col <= idx + uri.length
        wanted_uri = uri
        break
      end
    end
  end

  if wanted_uri
    uri = URI.parse(wanted_uri)
    if uri.class == URI::MailTo
      vim_puts("Composing new email to #{uri.to}.")
      VIM::command("call s:compose('#{uri.to}')")
    elsif uri.class == URI::MsgID
      msg = $curbuf.message(uri.opaque)
      if !msg
        vim_puts("Message not found in NotMuch database: #{uri.to_s}")
      else
        vim_puts("Opening message #{msg.message_id} in thread #{msg.thread_id}.")
        VIM::command("call s:Show('thread:#{msg.thread_id}', '#{msg.message_id}')")
      end
    else
      vim_puts("Opening #{uri.to_s}.")
      cmd = VIM::evaluate('g:notmuch_open_uri')
      # TODO(mash): Fix "Invalid channel 2" issue after calling this.
      # system(cmd, uri.to_s)
      VIM::command("!#{cmd} '#{uri.to_s}'")
    end
  else
    vim_puts('URI not found.')
  end
end

def save_patches(dir)
  if File.exists?(dir)
    q = $curbuf.query($curbuf.cur_thread)
    t = q.search_threads.first
    n = 0
    t.messages.each do |m|
      next if not m['subject'] =~ /\[PATCH.*\]/
      next if m['subject'] =~ /^Re:/
      subject = m['subject']
      # Sanitize for the filesystem
      subject.gsub!(/[^0-9A-Za-z.\-]/, '_')
      # Remove leading underscores.
      subject.gsub!(/^_+/, '')
      # git style numbered patchset format.
      file = "#{dir}/%04d-#{subject}.patch" % [n += 1]
      vim_puts "Saving patch to #{file}"
      system "notmuch show --format=mbox id:#{m.message_id} > #{file}"
    end
    vim_puts "Saved #{n} patch(es)"
  else
    VIM::command('redraw')
    vim_puts "ERROR: Invalid directory: #{dir}"
  end
end

def fold_range(from, to)
  VIM::command("normal #{from}G")
  VIM::command("normal zf#{to}G")
end

def fold_message(msg, fold_headers)
  fold_range(msg.full_header_start, msg.full_header_end-1) if fold_headers
  fold_range(msg.start, msg.end-1)
end

def gpg_passfunc(obj, uid_hint, passphrase_info, prev_was_bad, fd)
  pass = VIM::command("call inputsecret('Pass for %s%s: ')" % [uid_hint, prev_was_bad ? ' (X)' : ''])
  io = IO.for_fd(fd, 'w')
  io.puts pass
  io.flush
end

def show(thread_id, msg_id)
  show_full_headers = VIM::evaluate('g:notmuch_show_folded_full_headers') == 1
  showheaders = VIM::evaluate('g:notmuch_show_headers')
  gpgpin = VIM::evaluate('g:notmuch_gpg_pinentry') == 1

  $curbuf.cur_thread = thread_id
  messages = $curbuf.messages
  messages.clear
  focus_msg = nil
  $curbuf.render do |b|
    q = $curbuf.query(get_cur_view)
    q.sort = Notmuch::SORT_OLDEST_FIRST
    msgs = q.search_messages
    msgs.each do |msg|
      m = Mail.read(msg.filename)
      enc = false
      mime = false
      encfail = false
      mime = Mail::Gpg::encrypted_mime?(m)
      enc = mime || m.encrypted?
      if enc
        mail = m
        begin
          if gpgpin
            m = m.decrypt(:verify => true)
            VIM::command('silent! reset')
            VIM::command('redraw!')
          else
            m = m.decrypt(:verify => true,
                          :passphrase_callback => method(:gpg_passfunc),
                          :pinentry_mode => GPGME::PINENTRY_MODE_LOOPBACK)
          end
        rescue Exception
          m = mail
          encfail = true
        end
      end
      text_part = m.find_first_text
      nm_m = Message.new(msg, m)
      messages << nm_m
      date_fmt = VIM::evaluate('g:notmuch_show_date_format')
      date = Time.at(msg.date).strftime(date_fmt)
      nm_m.start = b.count
      b << 'From: %s %s (%s)' % [msg['from'], date, msg.tags]
      showheaders.each do |h|
        b << '%s: %s' % [h, m.header[h]]
      end
      if encfail
        b << 'Encryption: Error'
        b << ''
        nm_m.full_header_start = nm_m.full_header_end = b.count
        nm_m.body_start = b.count
        nm_m.end = b.count
        next
      end
      if enc
        b << 'Encryption: %s' % [mime ? 'PGP/Mime' : 'Inline']
      end
      if (enc && m.signatures.length != 0) || m.signed?
        begin
          verified = nil
          if enc
            verified = m
          else
            verified = m.verify
          end
          b << 'Signature: %s' % [verified.signature_valid? ? 'Valid' : 'Invalid']
          if verified.signature_valid?
            b << 'Signed by: %s' % [verified.signatures.map{|sig| sig.from}.join(', ')]
          end
        rescue Exception
          b << 'Signature: Error'
        end
      end
      nm_m.full_header_start = b.count
      if show_full_headers
        # Now show the rest in a folded area.
        m.header.fields.each do |k|
          # Only show the ones we haven't already printed out.
          if not showheaders.include?(k.name)
            b << '%s: %s' % [k.name, k.to_s]
          end
        end
        nm_m.full_header_end = b.count
      end
      m.all_parts.each_with_index do |part, index|
        b << 'Part %d: %s (%s)' % [index + 1, part.mime_type, format_filename(part.filename, index + 1, part.mime_type)]
      end
      nm_m.body_start = b.count
      b << '--- %s ---' % text_part.mime_type
      text_part.convert.each_line do |l|
        b << l.chomp
      end
      b << ''
      nm_m.end = b.count
      focus_msg = nm_m if !focus_msg and nm_m.tags.include?('unread')
      if !msg_id.empty? and nm_m.message_id == msg_id
        focus_msg = nm_m
      end
    end
    b.delete(b.count)
  end
  messages = $curbuf.messages
  messages.each_with_index do |msg, i|
    VIM::command("syntax region nmShowMsg#{i}Desc start='\\%%%il' end='\\%%%il' contains=@nmShowMsgDesc" % [msg.start, msg.start + 1])
    VIM::command("syntax region nmShowMsg#{i}Head start='\\%%%il' end='\\%%%il' contains=@nmShowMsgHead" % [msg.start + 1, msg.full_header_start])
    VIM::command("syntax region nmShowMsg#{i}Body start='\\%%%il' end='\\%%%dl' contains=@nmShowMsgBody" % [msg.body_start, msg.end - 1])

    fold_message(msg, show_full_headers)

    if msg.tags.include?('unread')
      VIM::command("normal #{msg.start}G")
      VIM::command('foldopen')
    end
  end
  focus_msg = messages[-1] if !focus_msg
  VIM::command("normal #{focus_msg.start}G")
  VIM::command('foldopen')
  scrolloff = VIM::evaluate('&scrolloff')
  VIM::command("normal #{scrolloff}j")
  VIM::command('normal zt')
end

def show_thread(mode)
  id = get_thread_id
  if not id.empty?
    case mode
    when 0;
    when 1; $cur_filter = nil
    when 2; $cur_filter = $cur_search
    end
    VIM::command("call s:Show('#{id}', '')")
  end
end

module DbHelper
  def init_dbhelper
    @db = Notmuch::Database.new($db_name)
    @queries = []
  end

  def query(*args)
    q = @db.query(*args)
    @queries << q
    q
  end

  def message(id)
    @db.find_message(id)
  end

  def close
    @queries.delete_if { |q| ! q.destroy! }
    @db.close
  end

  def reopen
    close if @db
    @db = Notmuch::Database.new($db_name)
  end

  def do_write
    db = Notmuch::Database.new($db_name, :mode => Notmuch::MODE_READ_WRITE)
    begin
      yield db
    ensure
      db.close
    end
  end
end

module URI
  class MsgID < Generic
  end

  @@schemes['ID'] = MsgID
end

class Message
  attr_accessor :start, :body_start, :end, :full_header_start, :full_header_end
  attr_reader :message_id, :filename, :mail, :tags

  def initialize(msg, mail)
    @message_id = msg.message_id
    @filename = msg.filename
    @mail = mail
    @start = 0
    @end = 0
    @full_header_start = 0
    @full_header_end = 0
    @tags = msg.tags
  end

  def to_s
    'id:%s' % @message_id
  end

  def inspect
    'id:%s, file:%s' % [@message_id, @filename]
  end
end

class StagedRender
  def initialize(buffer, enumerable, block)
    @b = buffer
    @enumerable = enumerable
    @block = block
    @last_render = 0

    @b.render { do_next }

    @last_render = @b.count
  end

  def is_ready?
    @last_render - @b.line_number <= $curwin.height
  end

  def do_next
    items = @enumerable.take($curwin.height * 2)
    return if items.empty?
    @block.call @b, items
    @last_render = @b.count
  end
end

class VIM::Buffer
  include DbHelper
  attr_accessor :messages, :threads, :cur_thread


  def init(name)
    @name = name
    @messages = []
    @threads = []

    init_dbhelper()
  end

  def <<(message)
    message.split("\n").each {
      |s| append(count(), s)
    }
  end

  def render_staged(enumerable, &block)
    StagedRender.new(self, enumerable, block)
  end

  def render
    old_count = count
    yield self
    (1..old_count).each do
      delete(1)
    end
  end
end

class Notmuch::Tags
  def to_s
    to_a.join(' ')
  end
end

class Notmuch::Message
  def to_s
    'id:%s' % message_id
  end
end

# workaround for bug in vim's ruby
class Object
  def flush
  end
end

module Mail

  class Message

    def find_first_text
      return self if not multipart?
      return text_part || html_part
    end

    def convert
      if mime_type != 'text/html'
        text = decoded
      else
        IO.popen(VIM::evaluate('exists("g:notmuch_html_converter") ? ' +
                               'g:notmuch_html_converter : "elinks --dump"'), 'w+') do |pipe|
          pipe.write(decode_body)
          pipe.close_write
          text = pipe.read
        end
      end
      text
    end

    def present
      buffer = ''
      header.fields.each do |f|
        buffer << "%s: %s\r\n" % [f.name, f.to_s]
      end
      buffer << "\r\n"
      buffer << body.to_s
      buffer
    end
  end
end

class String
  def to_utf8
    RUBY_VERSION >= '1.9' ? force_encoding('utf-8') : self
  end
end

get_config
