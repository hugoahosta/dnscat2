##
# controller_commands.rb
# Created August 29, 2015
# By Ron Bowes
#
# See: LICENSE.md
##

module ControllerCommands
  def _display_sessions(all = false)
    @sessions.keys.sort.each do |id|
      session = @sessions[id]

      if(all || session.state == Session::STATE_ESTABLISHED)
        # TODO: Implement session.to_s() properly so it can be used here
        @window.puts("Session %5d: %s" % [id, session.name()])
      end
    end
  end

  def _register_commands()
    @commander.register_command('echo',
      Trollop::Parser.new do
        banner("Print stuff to the terminal")
      end,

      Proc.new do |opts, optval|
        @window.puts(optval)
      end
    )

    @commander.register_command('sessions',
      Trollop::Parser.new do
        banner("Lists the current active sessions")
        opt :all, "Show dead sessions", :type => :boolean, :required => false
      end,

      Proc.new do |opts, optval|
        _display_sessions(opts[:all])
      end,
    )

    @commander.register_command("session",
      Trollop::Parser.new do
        banner("Interact with a session")
        opt :i, "Interact with the chosen session", :type => :integer, :required => false
      end,

      Proc.new do |opts, optval|
        if(opts[:i].nil?)
          _display_sessions(opts[:all])
        else
          session = @sessions[opts[:i]]
          if(session.nil?)
            @window.puts("Session #{opts[:i]} not found!")
            _display_sessions(false)
          else
            session.activate()
          end
        end
      end
    )

    @commander.register_command("set",
      Trollop::Parser.new do
        banner("set <name>=<value>")
      end,

      Proc.new do |opts, optarg|
        if(optarg.length == 0)
          @window.puts("Usage: set <name>=<value>")
          @window.puts()
          @window.puts("Global options:")
          Settings::GLOBAL.each_pair() do |k, v|
            @window.puts(" %s=%s" % [k, v.to_s()])
          end

          next
        end

        # Split at the '=' sign
        namevalue = optarg.split("=", 2)

        if(namevalue.length != 2)
          namevalue = optarg.split(" ", 2)
        end

        if(namevalue.length != 2)
          @window.puts("Bad argument! Expected: 'set <name>=<value>' or 'set name value'!")
          @window.puts()
          raise(Trollop::HelpNeeded)
        end

        begin
          Settings::GLOBAL.set(namevalue[0], namevalue[1], false)
        rescue Settings::ValidationError => e
          @window.puts("Failed to set the new value: #{e}")
        end
      end
    )

  end
end
