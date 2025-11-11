require "socket"
require "date"

MAX_BYTES = 2048
MAX_RELAY_BYTES = 2048
STARTING_UDP_PORT = 6256
TCP_PORT = ARGV[0] || 8554

class RTSPRelayServer
  def initialize(tcp_port = 8554, starting_udp_port = 6256)
    @paths = {}
    @accepted = 1
    @udp_port = starting_udp_port
    @tcp_port = tcp_port
    create_tcp_socket
  end

  def get_path(header)
    path = ''
    (0..(header.length)-(1+@tcp_port.to_s.length)).each do |x|
      if header[x..x+@tcp_port.to_s.length] == "#{@tcp_port}/"
        y = x+@tcp_port.to_s.length+1
        until header[y] == ' '
          path << header[y]
          y = y + 1
        end
        puts path
        return path
      end
    end
  end

  def create_udp_sockets()
    port_one = @udp_port
    socket_one = Socket.new Socket::AF_INET, Socket::SOCK_DGRAM
    socket_one.setsockopt :SOCKET, :REUSEPORT, true
    socket_addr_one = Socket.pack_sockaddr_in port_one, '0.0.0.0'
    socket_one.bind socket_addr_one

    @udp_port = @udp_port + 1
    port_two = @udp_port

    socket_two = Socket.new Socket::AF_INET, Socket::SOCK_DGRAM
    socket_two.setsockopt :SOCKET, :REUSEPORT, true
    socket_addr_two = Socket.pack_sockaddr_in port_two, '0.0.0.0'
    socket_two.bind socket_addr_two

    @udp_port = @udp_port + 10

    [socket_one, port_one, socket_two, port_two]
  end

  def create_tcp_socket()
    # RTSP Server
    @tcp_socket = Socket.new Socket::AF_INET, Socket::SOCK_STREAM
    @tcp_socket.setsockopt :SOCKET, :REUSEPORT, true
    socket_addr = Socket.pack_sockaddr_in @tcp_port, '0.0.0.0'
    @tcp_socket.bind socket_addr
    @tcp_socket.listen 5
  end

  def relay_rtp_rtcp(path)
    current_path = @paths["#{path}"]
    viewer_client_rtp_port = current_path[:viewer_client_rtp_port]
    viewer_client_rtcp_port = current_path[:viewer_client_rtcp_port]
    viewer_client_ip = current_path[:viewer_client_ip]

    client_rtp_addr = Socket.pack_sockaddr_in viewer_client_rtp_port, viewer_client_ip
    client_rtcp_addr = Socket.pack_sockaddr_in viewer_client_rtcp_port, viewer_client_ip

    puts "Relaying data to [rtp_port: #{viewer_client_rtp_port}, rtcp_port: #{viewer_client_rtcp_port}]"
    # Relaying RTP data
    rtp_thread = Thread.new do
      loop do
        rtp_data = current_path[:server_rtp_socket].recv(MAX_RELAY_BYTES)
        # puts "we got this rtp data #{rtp_data}"
        current_path[:relay_server_rtp_socket].send rtp_data, 0, client_rtp_addr
      end
    end

    # Relaying RTCP data
    loop do
      rtcp_data = current_path[:server_rtcp_socket].recv(MAX_RELAY_BYTES)
      current_path[:relay_server_rtcp_socket].send rtcp_data, 0, client_rtcp_addr
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

  def return_setup(header, path)
    server_rtp_socket, server_rtp_port, server_rtcp_socket, server_rtcp_port = create_udp_sockets()
    cseq = find_cseq header
    client_port = get_client_port header
    client_rtp_port = client_port.split("-")[0]
    client_rtcp_port = client_port.split("-")[1]
    date = Date.new(Date.today.year, Date.today.month, Date.today.day).strftime('%e %b %Y %H:%M:%S %Z')

    if @paths["#{path}"][:recording] == 0
      @paths["#{path}"][:streaming_client_rtp_port] = client_rtp_port
      @paths["#{path}"][:streaming_client_rtcp_port] = client_rtcp_port
      @paths["#{path}"][:server_rtp_port] = server_rtp_port
      @paths["#{path}"][:server_rtcp_port] = server_rtcp_port
      @paths["#{path}"][:server_rtcp_socket] = server_rtcp_socket
      @paths["#{path}"][:server_rtp_socket] = server_rtp_socket
    else
      @paths["#{path}"][:viewer_client_rtp_port] = client_rtp_port
      @paths["#{path}"][:viewer_client_rtcp_port] = client_rtcp_port
      @paths["#{path}"][:relay_server_rtp_port] = server_rtp_port
      @paths["#{path}"][:relay_server_rtcp_port] = server_rtcp_port
      @paths["#{path}"][:relay_server_rtcp_socket] = server_rtcp_socket
      @paths["#{path}"][:relay_server_rtp_socket] = server_rtp_socket
    end

    unless @paths["#{path}"][:recording] == 0
      "RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nDate: #{date}\r\nSession: 1\r\nTransport: RTP/AVP/UDP;unicast;client_port=#{client_port};server_port=#{server_rtp_port}-#{server_rtcp_port}\r\n\r"
    else
      "RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nDate: #{date}\r\nSession: 1\r\nTransport: RTP/AVP/UDP;unicast;client_port=#{client_port};server_port=#{server_rtp_port}-#{server_rtcp_port}\r\n\r"
    end
  end

  def return_describe(header, path)
    cseq = find_cseq header
    date = Date.new(Date.today.year, Date.today.month, Date.today.day).strftime('%e %b %Y %H:%M:%S %Z')
    sdp = @paths["#{path}"][:sdp]

    "RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nDate: #{date}\r\nContent-type: application/sdp\r\nContent-Length: #{sdp.length}\r\n\r\n#{sdp}"
  end

  def start()
    puts "Starting server on port #{TCP_PORT}"

    loop do
      client, client_addr = @tcp_socket.accept

      puts "Accepted #{@accepted} client: #{client_addr.ip_address}\n"
      @accepted = @accepted + 1

      thr = Thread.new do
        client_rtp_port = ''
        client_rtcp_port = ''
        path = ''

        loop do
          data = client.recvfrom(MAX_BYTES)[0]
          puts "Recieved Data:\n#{data}"

          method = get_method data

          case method
          when 'OPTIONS'
            path = get_path data
            if @paths["#{path}"] == nil
              @paths["#{path}"] = {recording: 0, sdp: '', streaming_client_ip: client_addr.ip_address, streaming_client: client}
            else
              @paths["#{path}"][:viewer_client] = client
              @paths["#{path}"][:viewer_client_ip] = client_addr.ip_address
            end
            options_return = return_options data
            puts "Returning:\n#{options_return}"
            client.puts options_return
          when 'ANNOUNCE'
            sdp = get_sdp data
            @paths["#{path}"][:sdp] = sdp

            announce_return = return_announce data
            puts "Returning:\n#{announce_return}"
            client.puts announce_return
          when 'SDP'
            sdp = data
            @paths["#{path}"][:sdp] = sdp

            puts "Received SDP method"
          when 'SETUP'
            setup_return = return_setup data, path
            puts "Returning:\n#{setup_return}"
            client.puts setup_return
          when 'RECORD'
            @paths["#{path}"][:recording] = 1
            record_return = return_record data
            puts "Returning:\n#{record_return}"
            client.puts record_return
          when 'DESCRIBE'
            describe_return = return_describe data, path
            puts "Returning:\n#{describe_return}"
            client.puts describe_return
          when 'PLAY'
            play_return = return_play data
            puts "Returning:\n#{play_return}"
            client.puts play_return
            relay_rtp_rtcp path
          else
            puts "Method not accepted"
          end
        end
      end
    end
  end
end

server = RTSPRelayServer.new(TCP_PORT, STARTING_UDP_PORT)
server.start
