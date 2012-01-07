require 'ffi'
require 'net/http'
require 'choice'
require 'mizuno/choices'
require 'childprocess'
require 'fileutils'
require 'etc'

module Mizuno
    #
    # Launches Mizuno when called from the command-line, and handles
    # damonization via FFI.
    #
    # Daemonization code based on Spoon.
    #
    class Runner
        extend FFI::Library

        ffi_lib 'c'
            
        attach_function :_setuid, :setuid, [ :uint ], :int

        attach_function :_setgid, :setgid, [ :uint ], :int

        #
        # Switch the process over to a new user id; will abort the
        # process if it fails. _options_ is the full list of options
        # passed to a server.
        #
        def Runner.setuid(options)
            entry = Etc.getpwnam(options[:user])
            die("Can't find --user named '#{options[:user]}'") unless entry
            return unless (_setuid(entry.uid) != 0)
            die("Can't switch to user '#{options[:user]}'")
        end

        #
        # Like setuid, but for groups.
        #
        def Runner.setgid(options)
            entry = Etc.getgrnam(options[:group])
            die("Can't find --group named '#{options[:group]}'") unless entry
            return unless (_setgid(entry.gid) != 0)
            die("Can't switch to group '#{options[:group]}'")
        end

        #
        # Launch Jetty, optionally as a daemon.
        #
        def Runner.start!
            # Default rackup is in config.ru
            config = (Choice.rest.first or "config.ru")

            # Create an options hash with only symbols.
            choices = Choice.choices.merge(:config => config)
            options = Hash[choices.map { |k, v| [ k.to_sym, v ] }]

            # Resolve relative paths to the logfile, etc.
            root = options[:root]
            options[:pidfile] = Runner.resolve_path(root, options[:pidfile])
            options[:log] = Runner.resolve_path(root, options[:log])
            options[:public] = Runner.resolve_path(root, options[:public])

            # Require multiple libraries.
            options.delete(:require).each { |r| require r }

            # Handle daemon-related commands.
            Runner.status(options) if options.delete(:status)
            Runner.reload(options) if options.delete(:reload)
            Runner.stop(options) if options.delete(:stop)
            Runner.kill(options) if options.delete(:kill)
            Runner.daemonize(options) if options.delete(:daemonize)

            # Fire up Mizuno as if it was called from Rackup.
            Dir.chdir(options[:root])
            server = Rack::Server.new
            server.options = options.merge(:server => 'mizuno')
            server.start
        end

        #
        # Relaunch as a daemon.
        #
        def Runner.daemonize(options)
            # Ensure that Mizuno isn't running.
            Runner.pid(options) and die("Mizuno is already running.")

            # Build a command line that should launch JRuby with the
            # appropriate options; this depends on the proper jruby
            # being in the $PATH
            config = options.delete(:config)
            args = Mizuno::LAUNCH_ENV.concat(options.map { |k, v| 
                (v.to_s.empty?) ? nil : [ "--#{k}", v.to_s ] }.compact.flatten)
            args.push(config)
            args.unshift('jruby')

            # Launch a detached child process.
            child = ChildProcess.build(*args)
            child.io.inherit!
            child.detach = true
            child.start
            File.open(options[:pidfile], 'w') { |f| f.puts(child.pid) }

            # Wait until the server starts or we time out waiting for it.
            exit if wait_for_server(options)
            child.stop
            die("Failed to start Mizuno.")
        end

        #
        # Return the status of a running daemon.
        #
        def Runner.status(options)
            die("Mizuno doesn't appear to be running.") \
                unless (pid = Runner.pid(options))
            die("Mizuno is running, but not online.") \
                unless(wait_for_server(options))
            die("Mizuno is running.", true)
        end

        #
        # Reload a running daemon by SIGHUPing it.
        #
        def Runner.reload(options)
            pid = Runner.pid(options) or die("Mizuno isn't running.")
            Process.kill("HUP", pid)
            die("Mizuno signaled to reload app.", true)
        end

        #
        # Stop a running daemon (SIGKILL)
        #
        def Runner.stop(options)
            pid = Runner.pid(options) or die("Mizuno isn't running.")
            print "Stopping Mizuno..."
            Process.kill("KILL", pid)
            die("failed") unless wait_for_server_to_die(options)
            FileUtils.rm(options[:pidfile])
            die("stopped", true)
        end

        #
        # Really stop a running daemon (SIGTERM)
        #
        def Runner.kill(options)
            pid = Runner.pid(options) or die("Mizuno isn't running.")
            puts "Terminating Mizuno with extreme prejudice..."
            Process.kill("TERM", pid)
            die("failed") unless wait_for_server_to_die(options)
            FileUtils.rm(options[:pidfile])
            die("stopped", true)
        end

        #
        # Transform a relative path to an absolute path.
        #
        def Runner.resolve_path(root, path)
            return(path) unless path.is_a?(String)
            return(path) if (path =~ /^\//)
            File.expand_path(File.join(root, path))
        end

        #
        # Fetches the PID from the :pidfile.
        #
        def Runner.pid(options)
            options[:pidfile] or die("Speficy a --pidfile to daemonize.") 
            return unless File.exists?(options[:pidfile])
            pid = File.read(options[:pidfile]).to_i

            # FIXME: This is a hacky way to get the process list, but I
            # haven't found a good cross-platform solution yet; this
            # should work on MacOS and Linux, possibly Solaris and BSD,
            # and almost definitely not on Windows.
            process = `ps ax`.lines.select { |l| l =~ /^\s*#{pid}\s*/ }
            return(pid) if (process.join =~ /\bmizuno\b/)

            # Stale pidfile; remove.
            $stderr.puts("Removing stale pidfile '#{options[:pidfile]}'")
            FileUtils.rm(options[:pidfile])
            return(nil)
        end

        #
        # Wait until _timeout_ seconds for a successful http connection;
        # returns true if we could connect and didn't get a server
        # error, false otherwise.
        #
        # FIXME: Check response status.
        #
        def Runner.wait_for_server(options, timeout = 10)
            begin
                Net::HTTP.start(options[:host], options[:port]) do |http|
                    http.read_timeout = timeout
                    response = http.get("/")
                    puts "**** response: #{response}"
                end
                return(true)
            rescue Errno::ECONNREFUSED => error
                return(false) unless ((timeout -= 0.5) > 0)
                sleep(0.5)
                retry
            rescue => error
                puts "**** http error: #{error}"
                return(false)
            end
        end

        #
        # Like wait_for_server, but returns true when the server goes
        # offline. If we hit _timeout_ seconds and the server is still
        # responding, returns false.
        #
        def Runner.wait_for_server_to_die(options, timeout = 10)
            begin
                while(timeout > 0)
                    Net::HTTP.start(options[:host], options[:port]) do |http|
                        http.read_timeout = timeout
                        response = http.get("/")
                        puts "**** (die) response: #{response}"
                    end
                    timeout -= 0.5
                    sleep(0.5)
                end
                return(false)
            rescue Errno::ECONNREFUSED => error
                return(true)
            rescue => error
                puts "**** http error: #{error}"
                return(true)
            end
        end

        #
        # Exit with a message and a status value.
        #
        # FIXME: Dump these in the logfile if called from HttpServer?
        #
        def Runner.die(message, success = false)
            $stderr.puts(message)
            exit(success ? 0 : 1)
        end
    end
end
