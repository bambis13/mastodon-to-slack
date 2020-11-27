# frozen_string_literal: true

require "bundler/setup"
require "net/https"
require "./lib/colorize.rb"
require "./lib/booleanize.rb"

Bundler.require
Dotenv.load

MASTODON_API_VERSION = "v1"
MASTODON_TIMELINE = "user"
MASTODON_ENDPOINT = "wss://#{ENV["MASTODON_INSTANCE_HOST"]}" \
                    "/api/#{MASTODON_API_VERSION}/streaming" \
                    "?access_token=#{ENV["MASTODON_ACCESS_TOKEN"]}" \
                    "&stream=#{MASTODON_TIMELINE}"
SLACK_WEBHOOK_URI = URI.parse(ENV["SLACK_WEBHOOK_URI"])
DISCHARGE_MODE = ENV.fetch("DISCHARGE_MODE", "false").booleanize

request = Net::HTTP::Post.new(SLACK_WEBHOOK_URI.request_uri)
http = Net::HTTP.new(SLACK_WEBHOOK_URI.host, SLACK_WEBHOOK_URI.port)
http.use_ssl = true

def start_connection(request, http)
  # https://github.com/faye/faye-websocket-ruby#initialization-options
  ws = Faye::WebSocket::Client.new(MASTODON_ENDPOINT, nil, ping: 60)

  ws.on :open do |_|
    puts "Connection starts".green
  end

  ws.on :message do |message|
    response = JSON.parse(message.data)

    if response.dig("event") == "update"
      payload = JSON.parse(response.dig("payload"))

      # The conditional expression below is redundant
      # because it does same thing in `if` statement and `elsif` statement.
      # However it is very complex to combine these statements.

      # ruby style referring to https://github.com/airbnb/ruby/blob/master/README.md#newlines
      if DISCHARGE_MODE &&
         # (payload.dig("visibility") == "public" || payload.dig("visibility") == "unlisted") &&
         (payload.dig("mentions").empty? || payload.dig("in_reply_to_account_id").nil?)
        post_to_slack(payload, request, http)
      elsif payload.dig("account", "acct") == ENV["MASTODON_USERNAME"] &&
            # (payload.dig("visibility") == "public" || payload.dig("visibility") == "unlisted") &&
            (payload.dig("mentions").empty? || payload.dig("in_reply_to_account_id").nil?) &&
            !payload.dig("reblogged")
        post_to_slack(payload, request, http)
      end
    end
    # follow back to add to notification target
    if response.dig("event") == "notification"
      payload = JSON.parse(response.dig("payload"))
      if payload.dig("type") == "follow"
        follow_back(JSON.parse(payload.dig("account", "id")))
      end
    end
  end

  ws.on :close do |_|
    puts "Connection closed".pink if ARGV[0] == "--verbose"

    # reopen the connection when closing it
    # https://stackoverflow.com/questions/22941084/faye-websocket-reconnect-to-socket-after-close-handler-gets-triggered
    start_connection(request, http)

    puts "Trying to reconnect...".yellow if ARGV[0] == "--verbose"
  end

  ws.on :error do |_|
    puts "Error occured".red if ARGV[0] == "--verbose"
  end
end

def post_to_slack(payload, request, http)
  mastodon_status_uri = payload.dig("url")

  request.body = {
    text: mastodon_status_uri,
    unfurl_links: true,
  }.to_json

  http.start do |h|
    h.request(request)
  end
end

def follow_back(user_id)
  _uri = "https://#{ENV["MASTODON_INSTANCE_HOST"]}" \
          "/api/#{MASTODON_API_VERSION}" \
          "/accounts/#{user_id}/follow" \
          "?access_token=#{ENV["MASTODON_ACCESS_TOKEN"]}"
  res = Net::HTTP.post_form(URI.parse(_uri),{})
  puts res.body
end

EM.run do
  start_connection(request, http)
end
