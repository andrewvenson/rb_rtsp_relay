require "socket"
require "date"

MAX_BYTES = 2000
MAX_RELAY_BYTES = 65536
SERVER_UDP_RTP_PORT = 6256
SERVER_UDP_RTCP_PORT = 6257
SERVER_UDP_RTP_RELAY_PORT = 8000
SERVER_UDP_RTCP_RELAY_PORT = 8001
PORT = ARGV[0] || 8554

# RTSP Server
socket = Socket.new Socket::AF_INET, Socket::SOCK_STREAM
socket.setsockopt :SOCKET, :REUSEPORT, true
socket_addr = Socket.pack_sockaddr_in PORT, '0.0.0.0'
socket.bind socket_addr
socket.listen 5

# RTP Socket for client to stream to
$rtp_socket = Socket.new Socket::AF_INET, Socket::SOCK_DGRAM
$rtp_socket.setsockopt :SOCKET, :REUSEPORT, true
rtp_socket_addr = Socket.pack_sockaddr_in SERVER_UDP_RTP_PORT, '0.0.0.0'
$rtp_socket.bind rtp_socket_addr

# RTCP Socket for client to stream to
$rtcp_socket = Socket.new Socket::AF_INET, Socket::SOCK_DGRAM
$rtcp_socket.setsockopt :SOCKET, :REUSEPORT, true
rtcp_socket_addr = Socket.pack_sockaddr_in SERVER_UDP_RTCP_PORT, '0.0.0.0'
$rtcp_socket.bind rtcp_socket_addr

# RTP socket for server to stream data to connecting viewer
$rtp_relay_socket = Socket.new Socket::AF_INET, Socket::SOCK_DGRAM
$rtp_relay_socket.setsockopt :SOCKET, :REUSEPORT, true
rtp_relay_socket_addr = Socket.pack_sockaddr_in SERVER_UDP_RTP_RELAY_PORT, '0.0.0.0'
$rtp_relay_socket.bind rtp_relay_socket_addr

# RTCP socket for server to stream data to connecting viewer
$rtcp_relay_socket = Socket.new Socket::AF_INET, Socket::SOCK_DGRAM
$rtcp_relay_socket.setsockopt :SOCKET, :REUSEPORT, true
rtcp_relay_socket_addr = Socket.pack_sockaddr_in SERVER_UDP_RTCP_RELAY_PORT, '0.0.0.0'
$rtcp_relay_socket.bind rtcp_relay_socket_addr

puts "Starting server on port #{PORT}"

def relay_rtp_rtcp(rtp_hash = {})
  # Receives RTP data from streaming client over udp socket
  puts "Sending data to rtp_port #{rtp_hash[:client_rtp_port]} && rtcp_port #{rtp_hash[:client_rtcp_port]}"

  client_rtp_addr = Socket.pack_sockaddr_in rtp_hash[:client_rtp_port], rtp_hash[:client_ip]
  client_rtcp_addr = Socket.pack_sockaddr_in rtp_hash[:client_rtcp_port], rtp_hash[:client_ip]

  # RTP
  rtp_thread = Thread.new do
    loop do
      rtp_data = $rtp_socket.recv(MAX_RELAY_BYTES)
      # puts "we got this rtp data #{rtp_data}"
      $rtp_relay_socket.send rtp_data, 0, client_rtp_addr
    end
  end

  # RTCP
  loop do
    rtcp_data = $rtcp_socket.recv(MAX_RELAY_BYTES)
    $rtcp_relay_socket.send rtcp_data, 0, client_rtcp_addr
  end
end

def find_cseq(header)
    counter = 0
    cseq = ''

    until counter == header.length - 6
      if header[counter..counter+5] == 'CSeq: '
        counter = counter+6
        until header[counter] == "\r"
          cseq << header[counter]
          counter = counter + 1
        end
        break
      end
      if cseq != ''
        break
      end

      counter = counter + 1
    end

    cseq.to_i
end

def get_client_port(header)
  client_port_length = 'client_port='.length
  client_port = ''

  (0..header.length-(1+client_port_length)).each do |x|
    if header[x..(x+client_port_length)-1] == 'client_port='
      y = x + client_port_length
      until [';',"\r"].include?(header[y])
        client_port << header[y]
        y = y + 1
      end
      return client_port
    end
  end
end

def get_sdp(header)
  break_length = "\r\n\r\n".length

  (0..header.length-(1+break_length)).each do |x|
    if header[x..(x+break_length)-1] == "\r\n\r\n"
      if ((x + break_length) - 1) == header.length - 1
        puts "wasn't with original"
        return ''
      else
        return header[((x+break_length)-1)+1..header.length-1]
      end
    end
  end
end

def get_method(header)
  if header[0..6] == 'OPTIONS'
    return 'OPTIONS'
  elsif header[0..7] == 'ANNOUNCE'
    return 'ANNOUNCE'
  elsif header[0..4] == 'SETUP'
    return 'SETUP'
  elsif header[0..5] == 'RECORD'
    return 'RECORD'
  elsif header[0..7] == 'DESCRIBE'
    return 'DESCRIBE'
  elsif header[0..2] == 'v=0'
    return 'SDP'
  elsif header[0..3] == 'PLAY'
    return 'PLAY'
  end
end

def return_options(header)
  cseq = find_cseq header
  "RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nPublic: DESCRIBE, ANNOUNCE, SETUP, TEARDOWN, PLAY, RECORD\r\n\r"
end

def return_announce(header)
  cseq = find_cseq header
  "RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\n\r"
end

def return_record(header)
  cseq = find_cseq header
  "RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nSession: 1\r\n\r"
end

def return_play(header)
  cseq = find_cseq header
  date = Date.new(Date.today.year, Date.today.month, Date.today.day).strftime('%e %b %Y %H:%M:%S %Z')
  "RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nSession: 1\r\nDate: #{date}\r\n\r"
end

def return_setup(header, recording)
  cseq = find_cseq header
  client_port = get_client_port header
  date = Date.new(Date.today.year, Date.today.month, Date.today.day).strftime('%e %b %Y %H:%M:%S %Z')

  unless recording == 0
    "RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nDate: #{date}\r\nSession: 1\r\nTransport: RTP/AVP/UDP;unicast;client_port=#{client_port};server_port=#{SERVER_UDP_RTP_RELAY_PORT}-#{SERVER_UDP_RTCP_RELAY_PORT}\r\n\r"
  else
    "RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nDate: #{date}\r\nSession: 1\r\nTransport: RTP/AVP/UDP;unicast;client_port=#{client_port};server_port=#{SERVER_UDP_RTP_PORT}-#{SERVER_UDP_RTCP_PORT}\r\n\r"
  end
end

def return_describe(header, sdp)
  cseq = find_cseq header
  date = Date.new(Date.today.year, Date.today.month, Date.today.day).strftime('%e %b %Y %H:%M:%S %Z')

  "RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nDate: #{date}\r\nContent-type: application/sdp\r\nContent-Length: #{sdp.length}\r\n\r\n#{sdp}"
end

accepted = 1
sdp = ''
recording = 0

loop do
  client, client_addr = socket.accept

  puts "Accepted #{accepted} client: #{client_addr.ip_address}\n"
  accepted = accepted + 1

  thr = Thread.new do
    client_rtp_port = ''
    client_rtcp_port = ''

    loop do
      data = client.recvfrom(MAX_BYTES)[0]

      puts "Recieved Data:\n#{data}"
      
      method = get_method data

      case method
      when 'OPTIONS'
        options_return = return_options data
        puts "Returning:\n#{options_return}"
        client.puts options_return
      when 'ANNOUNCE'
        sdp = get_sdp data
        announce_return = return_announce data
        puts "Returning:\n#{announce_return}"
        client.puts announce_return
      when 'SDP'
        sdp = data
        puts "Received SDP method"
      when 'SETUP'
        client_port = get_client_port data
        client_rtp_port = client_port.split("-")[0]
        client_rtcp_port = client_port.split("-")[1]

        setup_return = return_setup data, recording
        puts "Returning:\n#{setup_return}"
        client.puts setup_return
      when 'RECORD'
        recording = 1
        record_return = return_record data
        puts "Returning:\n#{record_return}"
        client.puts record_return
      when 'DESCRIBE'
        describe_return = return_describe data, sdp
        puts "Returning:\n#{describe_return}"
        client.puts describe_return
      when 'PLAY'
        play_return = return_play data
        puts "Returning:\n#{play_return}"
        client.puts play_return
        relay_rtp_rtcp({client_rtp_port:, client_rtcp_port:, client_ip: client_addr.ip_address})
      else
        puts "Method not accepted"
      end
    end
  end
end


socket.close
