require 'English'
module Pod
  class Command
    # GitLab扩展
    class Publish < Command

      GITLAB_API = 'https://gitlab.v.show/api/v4/'.freeze
      GITLAB_GROUP_ID = '26'.freeze
      GITLAB_VI_GROUP_ID = '520'.freeze
      GITLAB_TOKEN = (ENV['GIT_LAB_TOKEN']).to_s.freeze

      GET = 0
      POST = 1

      # 检查仓库状态 没有就创建一个新的仓库
      def check_remote_repo
        puts '-> 正在检查远程仓库状态...'.yellow unless @from_wukong
        project_id
      end

      def project_id
        params = {
          'search': @spec.name
        }
        response = send_request(GET, "/groups/#{GITLAB_VI_GROUP_ID}/projects", params) if @spec.name.include?('Vietnam')
        response = send_request(GET, "/groups/#{GITLAB_GROUP_ID}/projects", params) unless @spec.name.include?('Vietnam')

        projects = response.to_a.select { |p| p['name'] == @spec.name }
        unless projects.empty?
          puts '-> 获取项目ID成功！'.green unless @from_wukong
          return
        end
        puts '-> 正在创建远程仓库...'.yellow unless @from_wukong
        create_project
      end

      def create_project
        namespace_id = GITLAB_GROUP_ID
        namespace_id = GITLAB_VI_GROUP_ID if @spec.name.include?('Vietnam')
        params = {
          'name': @spec.name,
          'description': @spec.attributes_hash['summary'],
          'path': @spec.name,
          'namespace_id': namespace_id,
          'initialize_with_readme': false
        }
        response = send_request(POST, 'projects/', params)
        puts '-> 远程仓库创建成功！'.green unless @from_wukong
        ssh_url = response['ssh_url_to_repo']
        default_branch = response['default_branch']

        puts '-> 正在关联远程仓库...'.yellow unless @from_wukong
        command = "git branch -M #{default_branch} --quiet"

        # `git remote get-url --all origin`.to_s
        # command += ' && git remote remove origin'
        command += " && git remote add origin #{ssh_url}"
        command += ' && git add . && git commit -m "Initial commit" --quiet'
        command += ' && git push origin main --quiet'
        `#{command}`
        if $CHILD_STATUS.exitstatus != 0
          puts '-> 远程仓库关联失败！'.red
          clean
          Process.exit(1)
        end
        puts '-> 远程仓库关联成功！'.green unless @from_wukong
      end

      def get_project_id
        # 固定BTAssets版本号
        return 913 if @spec.name == 'BTAssets'

        puts "-> 正在获取项目ID: #{@spec.name}...".yellow unless @from_wukong
        params = {
          'search': @spec.name
        }
        response = send_request(GET, '/groups/27/projects', params)
        if response.nil?
          puts '-> 获取项目ID失败！'.red
          clean
          Process.exit(1)
        end
        projects = response.to_a.select { |p| p['name'] == @spec.name }
        unless projects.empty?
          puts '-> 获取项目ID成功！'.green unless @from_wukong
          return projects[0]['id']
        end

        puts '-> 项目ID不存在！'.red
        clean
        Process.exit(1)
      end

      def send_request(type, path, params = {}, host = GITLAB_API)
        uri = URI(host + path)

        if type == POST
          request = Net::HTTP::Post.new(uri)
          request.body = params.to_json
          request['Content-Type'] = 'application/json'
        else
          uri.query = URI.encode_www_form(params)
          request = Net::HTTP::Get.new(uri)
        end

        request['Authorization'] = "Bearer #{ENV['GIT_LAB_TOKEN']}"

        response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
          http.request(request)
        end

        if (200...300).include?(response.code.to_i)
          JSON(response.body)
        else
          puts "-> 接口请求失败：#{uri}, Authorization: Bearer #{GITLAB_TOKEN}".red
          puts "-> 响应Code：#{response.code}".red
          puts "-> 返回内容\n：#{JSON::pretty_generate(JSON(response.body))}".red
          clean
          Process.exit(1)
        end
      end

    end
  end
end
