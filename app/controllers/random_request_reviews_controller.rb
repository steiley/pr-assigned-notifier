class RandomRequestReviewsController < ApplicationController
  def create
    payload = JSON.parse(request.body.read)
    unless payload["action"] == "opened"
      head 204
      return
    end

    repository_info = get_repository_info(payload)
    response = request_reviewer(payload, repository_info)

    if response.status == 201
      head 201
      return
    end

    raise "#{response.status}:#{response.body}"
  end

  private

  def bear_graphql_http(payload)
    http = GraphQL::Client::HTTP.new("https://api.github.com/graphql") do
      attr_writer :token

      def headers(_context)
        {
          Authorization: "token #{@token}",
          Accept: "application/vnd.github.machine-man-preview+json"
        }
      end
    end
    http.token = AuthenticateService.perform(payload["installation"]["id"])
    http
  end

  def execute_graphql_http(http, document, variables = {})
    response = http.execute(document: document, variables: variables)

    raise response["errors"].first["message"] if response["errors"]

    response["data"]
  end

  def bear_faraday_connection
    Faraday.new(url: "https://api.github.com/") do |faraday|
      faraday.basic_auth("pr4-bot", ENV["PR4_BOT_KEY"])
      faraday.response :logger, Rails.logger
      faraday.adapter :net_http
    end
  end

  def pickup_reviewer(payload, repository_info)
    pr_user_login = payload["pull_request"]["user"]["login"]

    member_logins = repository_info["mentionableUsers"]["nodes"].map { |node| node["login"] }
    member_logins.delete(pr_user_login)
    member_logins.delete("pr4-bot")
    member_logins.sample
  end

  def request_reviewer(payload, repository_info)
    owner_login = payload["repository"]["owner"]["login"]

    conn = bear_faraday_connection
    conn.post do |req|
      req.url(
        %(/repos/#{owner_login}/#{payload["repository"]["name"]}/pulls/#{pr_number(payload)}/requested_reviewers)
      )

      req.headers["Accept"] = "application/vnd.github.thor-preview+json"
      req.body = JSON.generate(reviewers: [pickup_reviewer(payload, repository_info)])
    end
  end

  def get_repository_info(payload)
    http = bear_graphql_http(payload)

    repository_owner = payload["repository"]["owner"]["login"]

    execute_graphql_http(http, <<-QUERY)["repository"]

         query {
           repository(owner: "#{repository_owner}", name: "#{payload["repository"]["name"]}") {
             pullRequest(number: #{pr_number(payload)}) {
               id
             }
             mentionableUsers(last: 10) {
               nodes {
                 login
               }
             }
           }
         }
    QUERY
  end

  def pr_number(payload)
    payload["pull_request"]["number"]
  end
end
