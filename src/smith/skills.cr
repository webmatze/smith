require "path"
require "file_utils"
require "./paths"

module Smith::Skills
  struct Skill
    getter name : String
    getter description : String
    getter body : String
    getter path : String

    def initialize(@name : String, @description : String, @body : String, @path : String)
    end
  end

  class Catalog
    getter skills = Hash(String, Skill).new

    def self.discover(workspace_dir : String = Dir.current) : Catalog
      catalog = Catalog.new

      # 1. Global skills in ~/.smith/skills/
      global_skills_dir = File.join(Smith.home_dir, "skills")
      catalog.load_skills_dir(global_skills_dir)

      # 2. Local workspace skills in .smith/skills/, .gemini/skills/, .claude/skills/
      workspace_skills_dirs = [
        File.join(workspace_dir, ".smith", "skills"),
        File.join(workspace_dir, ".gemini", "skills"),
        File.join(workspace_dir, ".agents", "skills"),
      ]

      workspace_skills_dirs.each do |dir|
        catalog.load_skills_dir(dir)
      end

      catalog
    end

    def load_skills_dir(dir : String)
      return unless Dir.exists?(dir)

      Dir.children(dir).each do |child|
        skill_dir = File.join(dir, child)
        next unless Dir.exists?(skill_dir)

        skill_file = File.join(skill_dir, "SKILL.md")
        next unless File.exists?(skill_file)

        if skill = parse_skill_file(child, skill_file)
          @skills[skill.name] = skill
        end
      end
    end

    private def parse_skill_file(dir_name : String, file_path : String) : Skill?
      content = File.read(file_path)

      name = dir_name
      description = "No description provided."
      body = content

      # Simple YAML frontmatter parser
      if match = content.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\Z/m)
        frontmatter = match[1]
        body = match[2]

        frontmatter.each_line do |line|
          if line.starts_with?("name:")
            name = line.split(":", 2)[1].strip.delete("\"'")
          elsif line.starts_with?("description:")
            description = line.split(":", 2)[1].strip.delete("\"'")
          end
        end
      end

      Skill.new(name: name, description: description, body: body, path: file_path)
    end

    def summary_prompt : String?
      return nil if @skills.empty?

      String.build do |str|
        str.puts "\n--- Available Project & Global Skills ---"
        str.puts "You can execute/reference these skills when user mentions $skill-name or /skill-name:"
        @skills.values.each do |skill|
          str.puts "- **#{skill.name}**: #{skill.description}"
        end
      end
    end

    # Expands /skill_name or $skill_name in user prompt if present
    def expand_prompt(user_text : String) : String
      return user_text if @skills.empty?

      expanded = user_text
      skills_appended = Array(Skill).new

      # 1. Match slash invocation: /skill-name or /skill-name args...
      if user_text.starts_with?("/")
        parts = user_text.split(" ", 2)
        slash_cmd = parts[0][1..-1] # remove leading slash
        if skill = @skills[slash_cmd]?
          skills_appended << skill
          arg_suffix = parts[1]? ? "\nArguments: #{parts[1]}" : ""
          expanded = "Execute skill '#{skill.name}'#{arg_suffix}"
        end
      end

      # 2. Match $skill-name references in text
      @skills.each do |name, skill|
        pattern = "$#{name}"
        if user_text.includes?(pattern) && !skills_appended.includes?(skill)
          skills_appended << skill
        end
      end

      # If any skills matched, append full bodies to user turn
      if skills_appended.empty?
        expanded
      else
        String.build do |str|
          str.puts expanded
          skills_appended.each do |sk|
            str.puts "\n--- Skill Context: #{sk.name} (#{sk.path}) ---"
            str.puts sk.body
          end
        end
      end
    end
  end
end
