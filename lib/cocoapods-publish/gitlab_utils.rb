module Pod
  class Command
    class Publish < Command

      GITLAB_API = 'https://gitlab.v.show/api/v4/'
      GITLAB_GROUP_ID = '27'
      GITLAB_TOKEN = "#{ENV['GIT_LAB_TOKEN']}"

      GET = 0
      POST = 1

      # 上传文件到仓库
      def upload_zip_to_repo
        # 压缩
        UI.puts "-> 正在创建 #{@zip_file}...".yellow
        file_path = zip_file
        unless File.exist?(file_path)
          UI.puts "-> 二进制文件压缩失败！".red
          return
        end
        UI.puts "-> 二进制文件压缩成功！".green
        return unless @upload

        # 文件转成Base64格式
        b64 = Base64::encode64(File.open(file_path).read)

        project_id = get_project_id?
        return if project_id.nil?

        UI.puts "-> 正在上传 #{@zip_file}...".yellow
        # 上传
        params = {
          'branch' => 'main',
          'author_name' => 'yuxilong',
          'encoding' => 'base64',
          'content' => b64,
          'commit_message' => "[Update] #{@version}"
        }
        response = send_request?(POST, "/projects/#{project_id}/repository/files/#{@zip_file}", params)
        if response.nil?
          UI.puts "-> 上传zip失败！".red
          return
        end
        UI.puts "-> 上传成功！".green
        UI.puts "-> 接下来可以使用 pod publish BaiTuFrameworkPods #{@spec.name}.podspec --publish-framework 快速发布".green
      end

      # 压缩文件
      def zip_file
        zip_root_dir = File.dirname(Dir.new(@target_dir))
        `ditto #{@target_dir}/ios/#{@spec.name}.framework #{zip_root_dir}/tmp/#{@spec.name}.framework`
        resources_dir = "tmp/#{@spec.name}.framework/Versions/A/Resources"
        if Dir.exist?(resources_dir)
          `mv #{resources_dir}/*.bundle tmp/`
          `rm -rf #{resources_dir}`
          `rm -rf tmp/#{@spec.name}.framework/Resources`
        end

        if File.exist?("#{File.dirname(Dir.new(@target_dir))}/#{@zip_file}")
          `rm #{File.dirname(Dir.new(@target_dir))}/#{@zip_file}`
        end

        Dir.chdir("#{zip_root_dir}/tmp")
        `zip --symlinks -r -D -q #{@zip_file} ./`
        `mv #{@zip_file} "#{File.dirname(Dir.new(@target_dir))}"`
        Dir.chdir(@source_dir)
        `rm -rf #{zip_root_dir}/tmp`

        zip_path = "#{File.dirname(Dir.new(@target_dir))}/#{@zip_file}"
        if File.exist?("#{File.dirname(Dir.new(@target_dir))}/#{@zip_file}")
          `rm -rf #{@target_dir}`
        end
        zip_path
      end

      def get_project_id?
        UI.puts "-> 正在获取项目ID...".yellow
        response = send_request?(GET, "/groups/#{GITLAB_GROUP_ID}")
        if response.nil?
          UI.puts "-> 上传zip失败，获取项目ID失败！".red
          return
        end
        projects = response['projects']
        unless projects.select! { |p| p['name'].eql?(@spec.name) }.empty?
          UI.puts "-> 获取项目ID成功！".green
          return projects[0]['id']
        end
        UI.puts "-> 正在创建项目...".yellow
        create_project?
      end

      def create_project?
        params = {
          'name': @spec.name,
          'description': @spec.attributes_hash['summary'],
          'path': @spec.name,
          'namespace_id': GITLAB_GROUP_ID,
          'initialize_with_readme': false,
        }
        response = send_request?(POST, "projects/", params)

        unless response.nil?
          UI.puts "-> 项目创建成功！".green
          return response['id']
        end
        UI.puts "-> 项目创建失败！".red
      end

      def send_request?(type, path, params = {}, host = GITLAB_API)
        uri = URI(host + path)

        if type == POST
          request = Net::HTTP::Post.new(uri)
          request.body = params.to_json
          request['Content-Type'] = "application/json"
        else
          request = Net::HTTP::Get.new(uri)
        end

        request['Authorization'] = "Bearer #{ENV['GIT_LAB_TOKEN']}"

        response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
          http.request(request)
        end

        if (200...300).include?(response.code.to_i)
          JSON(response.body)
        else
          UI.puts "-> 接口请求失败：#{uri}, Authorization: Bearer #{GITLAB_TOKEN}".red
          UI.puts "-> 响应Code：#{response.code}".red
          UI.puts "-> 返回内容\n：#{JSON::pretty_generate(JSON(response.body))}".red
        end
      end
    end
  end
end
