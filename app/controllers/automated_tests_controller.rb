class AutomatedTestsController < ApplicationController
  include AutomatedTestsClientHelper

  before_action      :authorize_only_for_admin,
                     only: [:manage, :update, :download]
  before_action      :authorize_for_student,
                     only: [:student_interface,
                            :get_test_runs_students]

  # Update is called when files are added to the assignment
  def update
    @assignment = Assignment.find(params[:assignment_id])
    create_test_repo(@assignment)

    begin
      @assignment.transaction do
        new_files = process_test_form(@assignment, params, assignment_params)
        run_job = !new_files.empty? ||
                  @assignment.test_scripts.any?(&:marked_for_destruction?) ||
                  @assignment.test_support_files.any?(&:marked_for_destruction?)
        if @assignment.save
          # write the uploaded files
          new_files.each do |file|
            # TODO: Move write into the model
            File.open(file[:path], 'wb') do |f|
              content = file[:upload].read
              # remove carriage return or other non-LF whitespace from the end of lines
              if content.start_with?('#!')
                newline_chars = content[/\r?\n|\r{1,2}/] # captures line endings: "\n" "\r\n" "\r\r" "\r"
                if !newline_chars.nil? && newline_chars != "\n"
                  filename = File.basename file[:path]
                  flash_message(:notice, t('automated_tests.convert_newline_notice', file: filename))
                  content = content.encode(content.encoding, universal_newline: true)
                end
              end
              f.write(content)
            end
            # delete a replaced file if it was renamed
            if file.key?(:delete) && File.exist?(file[:delete])
              File.delete(file[:delete])
            end
          end
          if run_job
            AutotestScriptsJob.perform_later(request.protocol + request.host_with_port, @assignment.id)
          end
          flash_message(:success, t('assignment.update_success'))
        else
          flash_message(:error, @assignment.errors.full_messages)
        end
      end
    rescue => e
      flash_message(:error, e.message)
    ensure
      # TODO the page is not correctly drawn when using render
      redirect_to action: 'manage', assignment_id: params[:assignment_id]
    end
  end

  # Manage is called when the Automated Test UI is loaded
  def manage
    @assignment = Assignment.find(params[:assignment_id])
    @assignment.test_scripts.build(
      # TODO: make these default values
      run_by_instructors: true,
      run_by_students: false,
      display_input: :do_not_display,
      display_expected_output: :do_not_display,
      display_actual_output: :do_not_display
    )
    @assignment.test_support_files.build
    @student_tests_on = MarkusConfigurator.autotest_student_tests_on?
  end

  def student_interface
    @assignment = Assignment.find(params[:id])
    @student = current_user
    @grouping = @student.accepted_grouping_for(@assignment.id)

    unless @grouping.nil?
      @grouping.refresh_test_tokens
      # authorization
      begin
        authorize! @assignment, to: :run_tests? # TODO: Remove it when reasons will have the dependent policy details
        authorize! @grouping, to: :run_tests?
        @authorized = true
      rescue ActionPolicy::Unauthorized => e
        @authorized = false
        flash_now(:notice, e.result.reasons.full_messages.join(' '))
      end
    end

    render layout: 'assignment_content'
  end

  def execute_test_run
    begin
      assignment = Assignment.find(params[:id])
      grouping = current_user.accepted_grouping_for(assignment.id)
      grouping.refresh_test_tokens
      authorize! assignment, to: :run_tests? # TODO: Remove it when reasons will have the dependent policy details
      authorize! grouping, to: :run_tests?
      grouping.decrease_test_tokens
      test_scripts = assignment.select_test_scripts(current_user)
                               .pluck(:file_name, :timeout).to_h # {file_name1: timeout1, ...}
      hooks_script = assignment.select_hooks_script.pluck(:file_name)[0] # nil if not found
      test_run = grouping.create_test_run!(user: current_user)
      AutotestRunJob.perform_later(request.protocol + request.host_with_port, current_user.id, test_scripts,
                                   hooks_script, [{ id: test_run.id }])
      flash_message(:notice, I18n.t('automated_tests.tests_running'))
    rescue StandardError => e
      message = e.is_a?(ActionPolicy::Unauthorized) ? e.result.reasons.full_messages.join(' ') : e.message
      flash_message(:error, message)
    end
    redirect_to action: :student_interface, id: params[:id]
  end

  # Download is called when an admin wants to download a test script
  # or test support file
  # Check three things:
  #  1. filename is in DB
  #  2. file is in the directory it's supposed to be
  #  3. file exists and is readable
  def download
    if params[:type] == 'script'
      model_class = TestScript
    else # params[:type] == 'support'
      model_class = TestSupportFile
    end
    filedb = model_class.find_by(assignment_id: params[:assignment_id], file_name: params[:filename])

    if filedb
      filename = filedb.file_name
      assn_short_id = Assignment.find(params[:assignment_id]).short_identifier

      # the given file should be in this directory
      should_be_in = File.join(AutomatedTestsClientHelper::ASSIGNMENTS_DIR, assn_short_id)
      should_be_in = File.expand_path(should_be_in)
      filename = File.expand_path(File.join(should_be_in, filename))

      if should_be_in == File.dirname(filename) and File.readable?(filename)
        # Everything looks OK. Send the file over to the client.
        file_contents = IO.read(filename)
        send_file filename,
                  type: ( SubmissionFile.is_binary?(file_contents) ? 'application/octet-stream':'text/plain' ),
                  x_sendfile: true

        # print flash error messages
      else
        flash_message(:error, I18n.t('automated_tests.download_wrong_place_or_unreadable'))
        redirect_to action: 'manage'
      end
    else
      flash_message(:error, I18n.t('automated_tests.download_not_in_db'))
      redirect_to action: 'manage'
    end
  end

  def get_test_runs_students
    @grouping = current_user.accepted_grouping_for(params[:assignment_id])
    test_runs = @grouping.test_runs_students
    render json: test_runs.group_by { |t| t['test_runs.id'] }
  end

  def fetch_testers
    AutotestTestersJob.perform_later
    head :no_content
  end

  private

  def assignment_params
    params.require(:assignment)
        .permit(:enable_test,
                :enable_student_tests,
                :assignment_id,
                :tokens_per_period,
                :token_period,
                :token_start_date,
                :non_regenerating_tokens,
                :unlimited_tokens,
                test_files_attributes:
                    [:id, :filename, :filetype, :is_private, :_destroy],
                test_scripts_attributes:
                    [:id, :assignment_id, :seq_num, :file_name, :description,
                     :timeout, :run_by_instructors, :run_by_students,
                     :halts_testing, :display_description, :display_run_status,
                     :display_marks_earned, :display_input,
                     :display_expected_output, :display_actual_output,
                     :criterion_id, :_destroy],
                test_support_files_attributes:
                    [:id, :file_name, :assignment_id, :description, :_destroy])
  end
end
