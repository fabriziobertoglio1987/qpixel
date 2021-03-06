# Web controller. Provides actions that relate to questions - this is essentially the standard set of resources, plus a
# couple for the extra question lists (such as listing by tag).
class QuestionsController < ApplicationController
  before_action :authenticate_user!, :only => [:new, :create, :edit, :update, :destroy, :undelete, :close, :reopen]
  before_action :set_question, :only => [:show, :edit, :update, :destroy, :undelete, :close, :reopen]
  @@markdown_renderer = Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(), extensions = {})

  # Supplies a pre-constructed Markdown renderer for use in rendering Markdown from views.
  def self.renderer
    @@markdown_renderer
  end

  # Web action. Retrieves a paginated list of all the questions currently in the database for use by the view.
  def index
    @questions = Question.all.order('updated_at DESC').paginate(:page => params[:page], :per_page => 25)
  end

  # Web action. Retrieves a single question, specified by the query string parameter <tt>id</tt>.
  def show
    if user_signed_in? && current_user.has_privilege?('ViewDeleted')
      @answers = Answer.unscoped.where(:question => @question).order(params[:sort] || 'score desc')
    end
    @upvotes = @question.votes.where(:vote_type => 1).count
    @downvotes = @question.votes.where(:vote_type => -1).count
  end

  # Web action. Retrieves a paginated list of all questions where the tags contain a tag specified in the query string
  # parameter <tt>tag</tt>.
  def tagged
    @questions = Question.where('tags like ?', "%#{params[:tag]}%").order('updated_at DESC').paginate(:page => params[:page], :per_page => 50)
  end

  # Authenticated web action. Creates a new question as a resource for form creation in the view.
  def new
    @question = Question.new
  end

  # Authenticated web action. Based on data submitted from the <tt>new</tt> view, creates a new question. Explicitly
  # assigns tags to the question rather than relying on <tt>Question.create</tt> because the latter doesn't always work.
  # Also applies a default score and assigns the question to the currently signed in user.
  # Will redirect on completion; to the question page on success, or back to the <tt>new</tt> action on error.
  def create
    params[:question][:tags] = params[:question][:tags].split(" ")
    @question = Question.new question_params
    @question.tags = params[:question][:tags]
    @question.user = current_user
    @question.score = 0
    if @question.save
      redirect_to url_for(:controller => :questions, :action => :show, :id => @question.id)
    else
      render :new, :status => 400
    end
  end

  # Authenticated web action. Retrieves a single question for editing. Permission to perform this action is based on
  # three conditions: either (a) the editing user is the OP; (b) the editing user is a mod or admin; or (c) the editing
  # user has is at or over the editing privilege threshold (the <tt>EditPrivilegeThreshold</tt> setting.)
  def edit
    return unless check_your_privilege('Edit', @question)
  end

  # Authenticated web action. Based on the information submitted from the <tt>edit</tt> view, updates the question.
  # In a similar fashion to <tt>create</tt>, updates the tags explicitly because the standard <tt>update</tt> call
  # can't be relied on.
  def update
    return unless check_your_privilege('Edit', @question)
    params[:question][:tags] = params[:question][:tags].split(" ")
    PostHistory.question_edited(@question, current_user)
    if @question.update question_params
      @question.tags = params[:question][:tags]
      if @question.save
        redirect_to url_for(:controller => :questions, :action => :show, :id => @question.id)
      else
        render :edit
      end
    else
      render :edit
    end
  end

  # Authenticated web action. Marks the question as 'deleted' - that is, sets the <tt>is_deleted</tt> field to true.
  def destroy
    return unless check_your_privilege('Delete', @question)
    PostHistory.question_deleted(@question, current_user)
    @question.is_deleted = true
    @question.deleted_at = DateTime.now
    if @question.save
      calculate_reputation(@question.user, @question, -1)
      redirect_to url_for(:controller => :questions, :action => :show, :id => @question.id)
    else
      flash[:error] = "The question could not be deleted."
      redirect_to url_for(:controller => :questions, :action => :show, :id => @question.id)
    end
  end

  # Authenticated web action. Basically the opposite of <tt>:destroy</tt> - removes the <tt>is_deleted</tt> flag from
  # the question, making it visible from default scope again.
  def undelete
    return unless check_your_privilege('Delete', @question)
    PostHistory.question_undeleted(@question, current_user)
    @question.is_deleted = false
    @question.deleted_at = DateTime.now
    if @question.save
      calculate_reputation(@question.user, @question, 1)
      redirect_to url_for(:controller => :questions, :action => :show, :id => @question.id)
    else
      flash[:error] = "The question could not be undeleted."
      redirect_to url_for(:controller => :questions, :action => :show, :id => @question.id)
    end
  end

  def feed
    @questions = Rails.cache.fetch("questions_rss", :expires_in => 5.minutes) do
      Question.all.order(:created_at => :desc).limit(25)
    end
    respond_to do |format|
      format.rss { render :layout => false }
    end
  end

  def close
    unless check_your_privilege('Close', nil, false)
      render :json => { :status => 'failed', :message => 'You must have the Close privilege to close questions.' }, :status => 401 and return
    end

    if @question.is_closed
      render :json => { :status => 'failed', :message => 'Cannot close a closed question.' }, :status => 422 and return
    end

    if @question.update(:is_closed => true, :closed_by => current_user, :closed_at => Time.now)
      PostHistory.question_closed(@question, current_user)
      render :json => { :status => 'success', :closed_by => "<a href='/users/#{current_user.id}'>#{current_user.username}</a>" }
    else
      render :json => { :status => 'failed', :message => 'Question state could not be saved.' }, :status => 500
    end
  end

  def reopen
    unless check_your_privilege('Close', nil, false)
      render :json => { :status => 'failed', :message => 'You must have the Close privilege to reopen questions.' }, :status => 401 and return
    end

    if !@question.is_closed
      render :json => { :status => 'failed', :message => 'Cannot reopen an open question.' }, :status => 422 and return
    end

    if @question.update(:is_closed => false, :closed_by => current_user, :closed_at => Time.now)
      PostHistory.question_reopened(@question, current_user)
      render :json => { :status => 'success' }
    else
      render :json => { :status => 'failed', :message => 'Question state could not be saved.' }, :status => 500
    end
  end

  private
    # Sanitizes parameters for use by <tt>Question.create</tt> or <tt>Question.update</tt>. The only attributes that
    # users should be able to submit are <tt>:body</tt>, <tt>:title</tt>, and <tt>:tags</tt>; any other attributes
    # can either be inferred or defaulted to correct values.
    def question_params
      params.require(:question).permit(:body, :title, :tags)
    end

    # Retrives the question identified by the query string parameter <tt>id</tt>.
    def set_question
      begin
        @question = Question.find params[:id]
      rescue
        if current_user.has_privilege?('ViewDeleted')
          @question ||= Question.unscoped.find params[:id]
        end
        if @question.nil?
          render :template => 'errors/not_found', :status => 404
        end
      end
    end

    # Calculates and changes any reputation changes a user has had from a post. If <tt>direction</tt> is 1, we add the
    # reputation. If it's -1, we take it away.
    def calculate_reputation(user, post, direction)
      upvote_rep = post.votes.where(:vote_type => 1).count * get_setting('QuestionUpVoteRep').to_i
      downvote_rep = post.votes.where(:vote_type => -1).count * get_setting('QuestionDownVoteRep').to_i
      user.reputation += direction * (upvote_rep + downvote_rep)
      user.save!
    end
end

# Provides a custom HTML sanitization interface to use for cleaning up the HTML in questions.
class QuestionScrubber < Rails::Html::PermitScrubber
  # Sets up the scrubber instance with permissible tags and attributes.
  def initialize
    super
    self.tags = %w( a p b i em strong hr h1 h2 h3 h4 h5 h6 blockquote img strike del code pre br ul ol li )
    self.attributes = %w( href title src height width )
  end

  # Defines which nodes should be skipped when sanitizing HTML.
  def skip_node?(node)
    node.text?
  end
end
