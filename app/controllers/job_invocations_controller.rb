class JobInvocationsController < ApplicationController
  include ::Foreman::Controller::AutoCompleteSearch
  include ::ForemanTasks::Concerns::Parameters::Triggering
  include ::JobInvocationsChartHelper

  def new
    return @composer = prepare_composer if params[:feature].present?

    ui_params = {
      :host_ids => params[:host_ids],
      :targeting => {
        :targeting_type => Targeting::STATIC_TYPE,
        :bookmark_id => params[:bookmark_id],
      },
    }
    # replace an empty string search with a dummy search query to match all hosts
    # but only if search query was entered (based on presence of :search parameter)
    if params.key?(:search)
      query = params[:search].empty? ? "name != ''" : params[:search]
      ui_params[:targeting].update(:search_query => query)
    end

    if (template = JobTemplate.find_by(id: params[:template_id]))
      ui_params[:job_invocation] = {
        :job_category => template.job_category,
        :providers => {
          template.provider_type => {:job_template_id => template.id},
        },
      }
    end

    @composer = JobInvocationComposer.from_ui_params(ui_params)
  end

  def rerun
    job_invocation = resource_base.find(params[:id])
    @composer = JobInvocationComposer.from_job_invocation(job_invocation, params)
    @job_organization = Taxonomy.find_by(id: job_invocation.task.input[:current_organization_id])
    @job_location = Taxonomy.find_by(id: job_invocation.task.input[:current_location_id])
    render :action => 'new'
  end

  def legacy_create
    @composer = prepare_composer
    if @composer.trigger
      redirect_to job_invocation_path(@composer.job_invocation)
    else
      @composer.job_invocation.description_format = nil if params.fetch(:job_invocation, {}).key?(:description_override)
      render :action => 'new'
    end
  end

  def create
    @composer = prepare_composer
    if @composer.trigger
      redirect_to job_invocation_path(@composer.job_invocation)
    else
      redirect_to new_job_invocation_path({:inputs => params[:inputs], :feature => params[:feature], :host_ids => params[:host_ids]})
    end
  end

  def show
    @job_invocation = resource_base.includes(:template_invocations => :run_host_job_task).find(params[:id])
    @job_organization = Taxonomy.find_by(id: @job_invocation.task.input[:current_organization_id])
    @job_location = Taxonomy.find_by(id: @job_invocation.task.input[:current_location_id])
    @auto_refresh = @job_invocation.task.try(:pending?)

    respond_to do |format|
      format.json do
        targeting_hosts_resources
      end

      format.html
      format.js
    end
  end

  def index
    @job_invocations = resource_base_search_and_page.preload(:task, :targeting).order('job_invocations.id DESC')
  end

  # refreshes the form
  def refresh
    params[:job_invocation].delete :description_format if params[:job_invocation].key?(:description_override)
    @composer = prepare_composer
  end

  def chart
    find_resource
    render :json => {
      :finished => @job_invocation.finished?,
      :job_invocations => job_invocation_data(@job_invocation)[:columns],
      :statuses => {
        :success => @job_invocation.progress_report[:success],
        :cancelled => @job_invocation.progress_report[:cancelled],
        :failed => @job_invocation.progress_report[:error],
        :pending => @job_invocation.progress_report[:pending],
      },
    }
  end

  def preview_hosts
    composer = prepare_composer

    @hosts = composer.targeted_hosts.limit(Setting[:entries_per_page])
    @additional = composer.targeted_hosts.count - Setting[:entries_per_page]
    @dynamic = composer.targeting.dynamic?
    @query = composer.displayed_search_query

    render :partial => 'job_invocations/preview_hosts_list'
  end

  def cancel
    @job_invocation = resource_base.find(params[:id])
    result = @job_invocation.cancel(params[:force])

    if result
      flash[:info] = if params[:force]
                       _('Trying to abort the job')
                     else
                       _('Trying to cancel the job')
                     end
    else
      flash[:warning] = if params[:force]
                          _('The job cannot be aborted at the moment.')
                        else
                          _('The job cannot be cancelled at the moment.')
                        end
    end
    redirect_back(:fallback_location => job_invocation_path(@job_invocation))
  end

  def preview_job_invocations_per_host
    job_invocations = resource_base.search_for("targeted_host_id = #{params[:host_id]} and (status=#{params[:status]})").limit(params[:limit] || 3)

    job_invocations = job_invocations.map do |job|
      @job_invocation = job
      template_invocation = job.template_invocations.find { |template_inv| template_inv.host_id == params[:host_id].to_i }
      task = template_invocation.try(:run_host_job_task)
      status_mapper = task ? HostStatus::ExecutionStatus::ExecutionTaskStatusMapper.new(task) : job
      {
        start_at: job.start_at,
        description: job.description,
        id: job.id,
        status: status_mapper.status,
        status_label: status_mapper.status_label,
      }
    end
    render :json => {:job_invocations => job_invocations}
  end

  def list_jobs_hosts
    @job_invocation = resource_base.find(params[:id])
    hosts = @job_invocation.targeting.hosts.authorized(:view_hosts, Host)
    hosts = hosts.search_for(params[:search])
    template_invocations_task_by_hosts = {}
    hosts.each do |host|
      template_invocation = @job_invocation.template_invocations.find { |template_inv| template_inv.host_id == host.id }
      next unless template_invocation
      template_invocation_task = template_invocation.run_host_job_task
      template_invocations_task_by_hosts[host.id] =
        {
          :host_name => host.name,
          :id => host.id,
          :task => template_invocation_task.attributes.merge({cancellable: template_invocation_task.cancellable? }),
          :permissions => {
            :view_foreman_tasks => authorized_for(:permission => :view_foreman_tasks, :auth_object => template_invocation_task),
            :cancel_job_invocations => authorized_for(:permission => :cancel_job_invocations, :auth_object => @job_invocation),
            :execute_jobs => authorized_for(controller: :job_invocations, action: :create) && (!host.infrastructure_host? || User.current.can?(:execute_jobs_on_infrastructure_hosts)),
          },
        }
    end

    render json: {
      :template_invocations_task_by_hosts => template_invocations_task_by_hosts,
    }
  end

  private

  def action_permission
    case params[:action]
      when 'rerun'
        'create'
      when 'preview_hosts'
        'create'
      when 'cancel'
        'cancel'
      when 'chart', 'preview_job_invocations_per_host', 'list_jobs_hosts'
        'view'
      else
        super
    end
  end

  def prepare_composer
    if params[:feature].present?
      inputs = params[:inputs].permit!.to_hash if params.include?(:inputs)
      JobInvocationComposer.for_feature(
        params[:feature],
        params[:search].presence || params[:host_ids],
        inputs
      )
    else
      # triggering_params is a Hash
      #   when a hash is merged into ActionController::Parameters,
      #   it is assumed not to be #permitted?
      with_triggering = params.merge(:triggering => triggering_params)
      with_triggering[:triggering].permit!
      JobInvocationComposer.from_ui_params(with_triggering)
    end
  end

  def targeting_hosts_resources
    @auto_refresh = @job_invocation.task.try(:pending?)
    @resource_base = @job_invocation.targeting.hosts.authorized(:view_hosts, Host)

    unless params[:search].nil?
      @resource_base = @resource_base.joins(:template_invocations)
                                     .where(:template_invocations => { :job_invocation_id => @job_invocation.id})
    end
    @hosts = resource_base_search_and_page
    @total_hosts = resource_base_with_search.size
  end
end
