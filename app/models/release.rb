require 'date'

# FIXME this is simplified copypasta of the Burndown class from sprint.rb
class ReleaseBurndown
  class Series < Array
    def initialize(*args)
      @name = args.pop

      raise "Name '#{@name}' must be a symbol" unless @name.is_a?  Symbol
      super(*args)
    end

    attr_reader :name
  end

  def initialize(release, burn_direction = nil)
    burn_direction = burn_direction || Setting.plugin_redmine_backlogs[:points_burn_direction]

    @days = release.days
    @release_id = release.id

    # end date for graph
    days = @days
    daycount = days.size
    days = release.days(Date.today) if release.release_end_date > Date.today

    _series = ([nil] * days.size)

    # load cache
    day_index = to_h(days, (0..(days.size - 1)).to_a)
    ReleaseBurndownDay.find(:all, :order=>'day', :conditions => ["release_id = ?", release.id]).each {|data|
      day = day_index[data.day.to_date]
      next if !day

      _series[day] = [data.remaining_story_points.to_f]
    }

    # use initial story points for first day if not loaded from cache (db)
    _series[0] = [release.initial_story_points] unless _series[0]

    # fill out series
    last = nil
    _series = _series.enum_for(:each_with_index).collect{|v, i| v.nil? ? last : (last = v; v) }

    # DEBUG
    @s_check_1 = _series

    # make registered series
    remaining_story_points = _series.transpose
    make_series :remaining_story_points, remaining_story_points

    # calculate burn-up ideal
    # FIXME: not working yet
    if daycount == 1 # should never happen
      make_series :ideal, [remaining_story_points]
    else
      make_series :ideal, remaining_story_points.enum_for(:each_with_index).collect{|c, i| c * i * (1.0 / (daycount - 1)) }
    end

    # decide whether you want burn-up or down
    if burn_direction == 'down'
      @ideal.each_with_index{|v, i| @ideal[i] = @remaining_story_points[i] - v}
    end

    @max = @available_series.values.flatten.compact.max
  end

  attr_reader :days
  attr_reader :release_id
  attr_reader :max

  attr_reader :remaining_story_points
  attr_reader :ideal

  # DEBUG
  attr_accessor :s_check_1

  def series(select = :active)
    return @available_series.values.select{|s| (select == :all) }.sort{|x,y| "#{x.name}" <=> "#{y.name}"}
  end

  private

  def cache(day, points)
    datapoint = {
      :day => day,
      :release_id => @release_id,
      :remaining_story_points => points
    }
    rbdd = ReleaseBurndownDay.new datapoint
    rbdd.save!
  end

  def make_series(name, data)
    @available_series ||= {}
    s = ReleaseBurndown::Series.new(data, name)
    @available_series[name] = s
    instance_variable_set("@#{name}", s)
  end

  def to_h(keys, values)
    return Hash[*keys.zip(values).flatten]
  end

end

class Release < ActiveRecord::Base
    unloadable

    belongs_to :project
    has_many :release_burndown_days

    validate :start_and_end_dates

    def start_and_end_dates
        errors.add_to_base("Release cannot end before it starts") if self.release_start_date && self.release_end_date && self.release_start_date >= self.release_end_date
    end

    def stories
        return Story.product_backlog(@project)
    end

    def days(cutoff = nil)
        # assumes mon-fri are working days, sat-sun are not. this
        # assumption is not globally right, we need to make this configurable.
        cutoff = self.release_end_date if cutoff.nil?
        return (self.release_start_date .. cutoff).select {|d| (d.wday > 0 and d.wday < 6) }
    end

    def has_burndown?
        return !!(self.release_start_date and self.release_end_date and self.initial_story_points)
    end

    def burndown(burn_direction = nil)
        return nil if not self.has_burndown?
        @cached_burndown ||= ReleaseBurndown.new(self, burn_direction)
        return @cached_burndown
    end

end
