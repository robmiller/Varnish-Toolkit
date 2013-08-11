require 'rubygems'
require 'hpricot'
require 'net/http'
require 'parallel'

module Varnisher
  class PagePurger
    
    def initialize(url)
      @url = url
      @uri = URI.parse(url)
      
      @urls = []
      
      # First, purge the URL itself; that means we'll get up-to-date references within that page.
      puts "Purging #{@url}...\n\n"
      purge(@url)
      
      # Then, do a fresh GET of the page and queue any resources we find on it.
      puts "Looking for external resources on #{@url}..."

      if $options[:verbose]
        puts "\n\n"
      end

      fetch_page(@url)

      if $options[:verbose]
        puts "\n"
      end

      puts "#{@urls.length} total resources found.\n\n"

      if @urls.length == 0
        puts "No resources found. Abort!"
        return
      end
      
      # Let's figure out which of these resources we can actually purge — whether they're on our server, etc.
      puts "Tidying resources...\n"
      tidy_resources
      puts "#{@urls.length} purgeable resources found.\n\n"
      
      # Now, purge all of the resources we just queued.
      puts "Purging resources..."

      if $options[:verbose]
        puts "\n\n"
      end

      purge_queue

      if $options[:verbose]
        puts "\n"
      end
      
      puts "Nothing more to do!\n\n"
    end
    
    # Sends a PURGE request to the Varnish server, asking it to purge the given URL from its cache.
    def purge(url)
      begin
        uri = URI.parse(URI.encode(url.to_s.strip))
      rescue
        puts "Couldn't parse URL for purging: #{$!}"
        return
      end

      s = TCPSocket.open(PROXY_HOSTNAME, PROXY_PORT)
      s.print("PURGE #{uri.path} HTTP/1.1\r\nHost: #{uri.host}\r\n\r\n")

      if $options[:verbose]
        if s.read =~ /HTTP\/1\.1 200 Purged\./
          puts "Purged  #{url}"
        else
          puts "Failed to purge #{url}"
        end
      end

      s.close
    end
    
    # Fetches a page and parses out any external resources (e.g. JavaScript files, images, CSS files) it finds on it.
    def fetch_page(url)
      begin
        uri = URI.parse(URI.encode(url.to_s.strip))
      rescue
        puts "Couldn't parse URL for resource-searching: #{url}"
        return
      end
      
      headers = {
        "User-Agent"     => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_2) AppleWebKit/535.2 (KHTML, like Gecko) Chrome/15.0.874.106 Safari/535.2",
        "Accept-Charset" => "utf-8", 
        "Accept"         => "text/html"
      }
      
      begin
        doc = Hpricot(Net::HTTP.get_response(uri).body)
      rescue
        puts "Hmm, I couldn't seem to fetch that URL. Sure it's right?\n"
        return
      end

      find_resources(doc) do |resource|
        if $options[:verbose]
            puts "Found #{resource}"
          end
        queue_resource(resource)
      end
    end

    def find_resources(doc)
      return unless doc.respond_to? 'search'

      # A bash at an abstract representation of resources. All you need is an XPath, and what attribute to select from the matched elements.
      resource = Struct.new :name, :xpath, :attribute
      resources = [ 
        resource.new('stylesheet', 'link[@rel*=stylesheet]', 'href'),
        resource.new('JavaScript file', 'script[@src]', 'src'),
        resource.new('image file', 'img[@src]', 'src')
      ]

      resources.each { |resource|
        doc.search(resource.xpath).each { |e|
          att = e.get_attribute(resource.attribute)
          yield att
        }
      }
    end
    
    # Adds a URL to the processing queue.
    def queue_resource(url)
      @urls << url.to_s
    end
    
    def tidy_resources
      valid_urls = []
      
      @urls.each { |url|
        # If we're dealing with a host-relative URL (e.g. <img src="/foo/bar.jpg">), absolutify it.
        if url.to_s =~ /^\//  
          url = @uri.scheme + "://" + @uri.host + url.to_s
        end

        # If we're dealing with a path-relative URL, make it relative to the current directory.
        unless url.to_s =~ /[a-z]+:\/\//
          # Take everything up to the final / in the path to be the current directory.
          /^(.*)\//.match(@uri.path)
          url = @uri.scheme + "://" + @uri.host + $1 + "/" + url.to_s
        end
        
        begin
          uri = URI.parse(url)
        rescue
          next 
        end
        
        # Skip URLs that aren't HTTP, or that are on different domains.
        next if uri.scheme != "http"
        next if uri.host != @uri.host

        valid_urls << url
      }

      @urls = valid_urls.dup
    end
    
    # Processes the queue of URLs, sending a purge request for each of them.
    def purge_queue()
      Parallel.map(@urls) { |url|
        if $options[:verbose]
          puts "Purging #{url}..."
        end

        purge(url)
      }
    end

  end
end
