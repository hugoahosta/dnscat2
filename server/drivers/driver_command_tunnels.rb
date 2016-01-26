##
# driver_command_tunnels.rb
# Created November 27, 2015
# By Ron Bowes
#
# See: LICENSE.md
##

require 'uri'

require 'libs/command_helpers'
require 'libs/socketer'

module DriverCommandTunnels
  def create_via_socket(host, port, on_ready)
    tunnel_id = nil

    # Ask the client to make a connection for us
    packet = CommandPacket.new({
      :is_request => true,
      :request_id => request_id(),
      :command_id => CommandPacket::TUNNEL_CONNECT,
      :options    => 0,
      :host       => host,
      :port       => port,
    })

    _send_request(packet, Proc.new() do |request, response|
      # Handle an error response
      if(response.get(:command_id) == CommandPacket::COMMAND_ERROR)
        @window.puts("Connect failed: #{response.get(:reason)} #{e}")
        next
      end

      # Create a socket pair
      v_socket, socket = UNIXSocket.pair()

      # Get the tunnel_id
      tunnel_id = response.get(:tunnel_id)

      # Start a receive thread for the socket
      thread = Thread.new() do
        begin
          loop do
            data = v_socket.recv(Socketer::BUFFER)

            _send_request(CommandPacket.new({
              :is_request => true,
              :request_id => request_id(),
              :command_id => CommandPacket::TUNNEL_DATA,
              :tunnel_id  => tunnel_id,
              :data       => data,
            }), nil)
          end
        rescue StandardError => e
          puts("Error in via_socket receive thread: #{e}")
          close_via_socket(tunnel_id)
        end
      end


      # We need to save the socket in our list of instances so we can feed
      # data to it later
      @via_sockets = @via_sockets || {}
      @via_sockets[tunnel_id] = {
        :v_socket => v_socket,
        :thread   => thread,
      }

      # Pass the socket back to the caller
      on_ready.call(socket, tunnel_id)
    end)
  end

  def close_via_socket(tunnel_id, send_close = false)
    via_socket = @via_sockets.delete(tunnel_id)
    if(via_socket.nil?)
      @window.puts("Tried to close a socket that doesn't exist: tunnel %d" % tunnel_id)
      return
    end

    if(send_close)
      _send_request(CommandPacket.new({
        :is_request => true,
        :request_id => request_id(),
        :command_id => CommandPacket::TUNNEL_CLOSE,
        :tunnel_id  => tunnel_id,
        :reason     => "Socket closed",
      }), nil)
    end

    via_socket[:v_socket].close()

    # Note: do this last in case we're in this thread. :)
    if(via_socket[:thread])
      via_socket[:thread].exit()
    end
  end

  def _parse_host_ports(str)
    local, remote = str.split(/ /)

    if(remote.nil?)
      @window.puts("Bad argument! Expected: 'listen [<lhost>:]<lport> <rhost>:<rport>'")
      @window.puts()
      raise(Trollop::HelpNeeded)
    end

    # Split the local port at the :, if there is one
    if(local.include?(":"))
      local_host, local_port = local.split(/:/)
    else
      local_host = '0.0.0.0'
      local_port = local
    end
    local_port = local_port.to_i()

    if(local_port <= 0 || local_port > 65535)
      @window.puts("Bad argument! lport must be a valid port (between 0 and 65536)")
      @window.puts()
      raise(Trollop::HelpNeeded)
    end

    remote_host, remote_port = remote.split(/:/)
    if(remote_host == '' || remote_port == '' || remote_port.nil?)
      @window.puts("rhost or rport missing!")
      @window.puts()
      raise(Trollop::HelpNeeded)
    end
    remote_port = remote_port.to_i()

    if(remote_port <= 0 || remote_port > 65535)
      @window.puts("Bad argument! rport must be a valid port (between 0 and 65536)")
      @window.puts()
      raise(Trollop::HelpNeeded)
    end

    return local_host, local_port, remote_host, remote_port
  end

  def _register_commands_tunnels()
    @sessions = {}
    @via_sockets = {}

    @commander.register_command('wget',
      Trollop::Parser.new do
        banner("Perform an HTTP download via an established tunnel")
      end,

      Proc.new do |opts, optarg|
        uri = URI(optarg)

        if(uri.nil?)
          @window.puts("Sorry, that URL was invalid! They need to start with 'http://'")
          next
        end

        if(uri.scheme.downcase != 'http')
          @window.puts("Sorry, we only support http requests right now (and possibly forevermore)")
          next
        end

        page = ''
        create_via_socket(uri.host, uri.port, Proc.new() do |socket, tunnel_id|
          Socketer::Manager.new(socket, {
            :on_ready => Proc.new() do |manager|
              @window.puts("Connection successful: #{uri.host}:#{uri.port}")

              request = [
                "GET #{uri.path}?#{uri.query} HTTP/1.0",
                "Host: #{uri.host}:#{uri.port}",
                "Connection: close",
                "Cache-Control: max-age=0",
                "User-Agent: #{NAME} v#{VERSION}",
                "DNT: 1",
                "",
              ]

              manager.write(request.join("\r\n") + "\r\n")
            end,
            :on_close => Proc.new() do |manager, msg, e|
              puts("Received %d bytes!" % page.length)
              puts(page)
            end,
            :on_data => Proc.new() do |manager, data|
              page += data
            end,
          }).ready!()
        end)
      end
    )

#    @commander.register_command('tunnels',
#      Trollop::Parser.new do
#        banner("Lists all current listeners")
#      end,
#
#      Proc.new do |opts, optarg|
#        @tunnels.each do |tunnel|
#          @window.puts(tunnel.to_s)
#        end
#      end
#    )

    @commander.register_command('listen',
      Trollop::Parser.new do
        banner("Listens on a local port and sends the connection out the other side (like ssh -L). Usage: listen [<lhost>:]<lport> <rhost>:<rport>")
      end,

      Proc.new do |opts, optarg|
        lhost, lport, rhost, rport = _parse_host_ports(optarg)
        @window.puts("Listening on #{lhost}:#{lport}, sending connections to #{rhost}:#{rport}")

        begin
          # Listen until we get a connection
          Socketer::Listener.new(lhost, lport, Proc.new() do |s|
            # When the connection arrives, create the "remote" socket
            create_via_socket(rhost, rport, Proc.new() do |v_socket, tunnel_id|
              # These will be filled in shortly
              local_socket = nil
              via_socket   = nil

              local_socket = Socketer::Manager.new(s, {
                :on_ready => Proc.new() do |manager|
                  puts("local_socket is ready!")
                end,
                :on_data => Proc.new() do |manager, data|
                  puts("local_socket got data!")
                  via_socket.write(data)
                end,
                :on_error => Proc.new() do |manager, msg, e|
                  puts("local_socket#on_error #{manager} #{msg} #{e}")
                  close_via_socket(tunnel_id, true)
                end,
                :on_close => Proc.new() do |manager|
                  puts("local_socket#on_close #{manager}")
                  close_via_socket(tunnel_id, true)
                end,
              })

              # Set up the manager for the "local" socket
              via_socket = Socketer::Manager.new(v_socket, {
                :on_ready => Proc.new() do |manager|
                  puts("via_socket is ready!")
                  local_socket.ready!()
                end,
                :on_data => Proc.new() do |manager, data|
                  puts("via_socket got data!")
                  local_socket.write(data)
                end,
                :on_error => Proc.new() do |manager, msg, e|
                  puts("via_socket#on_error #{manager} #{msg} #{e}")
                  local_socket.close()
                end,
                :on_close => Proc.new() do |manager|
                  puts("via_socket#on_close #{manager}")
                  local_socket.close()
                end,
              })
              via_socket.ready!()
            end)
          end)
        rescue Errno::EACCES => e
          @window.puts("Sorry, couldn't listen on that port: #{e}")
        rescue Errno::EADDRINUSE => e
          @window.puts("Sorry, that address:port is already in use: #{e}")
          # TODO: Better error msg
        rescue Exception => e
          @window.puts("An exception occurred: #{e}")
        end
      end
    )
  end

  def tunnel_data_incoming(packet)
    tunnel_id = packet.get(:tunnel_id)
    via_socket = @via_sockets[tunnel_id]

    if(via_socket.nil?)
      @window.puts("Received data for an unknown via_socket: %d" % tunnel_id)
      return
    end

    case packet.get(:command_id)
    when CommandPacket::TUNNEL_DATA
      puts("Received TUNNEL_DATA")
      via_socket[:v_socket].write(packet.get(:data))

    when CommandPacket::TUNNEL_CLOSE
      puts("Received TUNNEL_CLOSE")
      close_via_socket(tunnel_id)
    else
      raise(DnscatException, "Unknown command sent by the server: #{packet}")
    end
  end

  def tunnels_stop()
#    if(@tunnels.length > 0)
#      @window.puts("Stopping active tunnels...")
#      @tunnels.each do |t|
#        t.kill()
#      end
#    end
  end
end