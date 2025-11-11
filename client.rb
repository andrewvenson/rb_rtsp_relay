require "socket"

PORT = ARGV[0] || 554

socket = Socket.new Socket::AF_INET, Socket::SOCK_STREAM
socket_addr = Socket.pack_sockaddr_in PORT, '127.0.0.1'
socket.connect socket_addr

while line = socket.gets
  puts "Server Response: #{line}"
  input = $stdin.readline
  socket.puts input
  if input.scan("end\n").length > 0
    puts "Connection ended"
    break
  end
end

socket.close
