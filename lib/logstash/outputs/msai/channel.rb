# encoding: utf-8

class LogStash::Outputs::Msai
  class Channel

    attr_reader :intrumentation_key
    attr_reader :table_id
    attr_reader :failed_on_upload_retry_Q
    attr_reader :failed_on_notify_retry_Q
    attr_reader :event_format_ext
    attr_reader :blob_max_delay

    public

    def initialize ( intrumentation_key, table_id )
      @closing = false
      configuration = Config.current

      @logger = configuration[:logger]

      @logger.debug { "Create a new channel, intrumentation_key / table_id : #{intrumentation_key} / #{table_id}" }
      @intrumentation_key = intrumentation_key
      @table_id = table_id
      set_event_format_ext( configuration )
      set_table_properties( configuration )
      @semaphore = Mutex.new
      @failed_on_upload_retry_Q = Queue.new
      @failed_on_notify_retry_Q = Queue.new
      @workers_channel = {  }
      @active_blobs = [ Blob.new( self, 1 ) ]
      @state = State.instance

      launch_upload_recovery_thread
      launch_notify_recovery_thread
    end

    def close
      @closing = true
      @active_blobs.each do |blob|
        blob.close
      end
    end

    def stopped?
      @closing
    end

    def << ( event )
      if @data_field && event[@data_field]
        serialized_event = serialize_data_field( event[@data_field] )
      else
        serialized_event = ( EXT_EVENT_FORMAT_CSV == @event_format_ext ? serialize_to_csv( event ) : serialize_to_json( event ) )
      end
      if serialized_event
        sub_channel = @workers_channel[Thread.current] || @semaphore.synchronize { @workers_channel[Thread.current] = Sub_channel.new( @event_separator ) }
        sub_channel << serialized_event
      else
        @logger.warn { "event not uploaded, no relevant data in event. table_id: #{table_id}, event: #{event}" }
      end
    end


    def collect_blocks
      workers_channel = @semaphore.synchronize { @workers_channel.dup }
      full_block_list = [  ]
      prev_last_block = nil

      workers_channel.each_value do |worker_channel|
        block_list = worker_channel.get_block_list!
        unless block_list.empty?
          last_block = block_list.pop
          full_block_list.concat( block_list )
          if prev_last_block
            unless prev_last_block.concat( last_block )
              full_block_list << prev_last_block
              prev_last_block = last_block
            end
          else
            prev_last_block = last_block
          end
        end
      end
      full_block_list << prev_last_block if prev_last_block
      full_block_list
    end


    def enqueue_blocks ( block_list )
      block_list.each do |block|
        block.seal
        find_blob << block
      end
    end


    private

    def launch_upload_recovery_thread
      #recovery thread
      Thread.new do
        next_block = nil
        loop do
          block_to_upload = next_block || @failed_on_upload_retry_Q.pop
          next_block = nil
          until Clients.instance.storage_account_state_on? do
            Stud.stoppable_sleep( 60 ) { stopped? }
          end
          if block_to_upload
            find_blob << block_to_upload
          end
        end
      end
    end


    # thread that failed to notify due to Application Isights error, such as wrong key or wrong schema
    def launch_notify_recovery_thread
      #recovery thread
      Thread.new do
        loop do
          tuple ||= @failed_on_notify_retry_Q.pop
          begin
            Stud.stoppable_sleep( 60 ) { stopped? }
          end until Clients.instance.storage_account_state_on? || stopped?
          if  stopped?
            @state.dec_pending_notifications
          else
            Blob.new.notify( tuple )
          end
        end
      end
    end


    def serialize_data_field ( data )
      serialized_data = nil
      if data.is_a?( String )
        serialized_data = data
      elsif EXT_EVENT_FORMAT_CSV == @event_format_ext
        if data.is_a?( Array )
          serialized_data = data.to_csv( :col_sep => @csv_separator )
        elsif data.is_a?( Hash )
          serialized_data = serialize_to_csv( data )
        end
      elsif EXT_EVENT_FORMAT_JSON == @event_format_ext
        if data.is_a?( Hash )
          serialized_data = serialize_to_json( data )
        elsif data.is_a?( Array ) && @fields_map && !@fields_map.empty?
          serialized_data = serialize_to_json( Hash[@fields_map.map {|field| field[:name]}.zip( data )] )
        end
      end
      serialized_data
    end


    def serialize_to_json ( event )
      return event.to_json unless @fields_map && !@fields_map.empty?

      json_hash = {  }
      @fields_map.each do |column|
        value = event[column[:name]] || column[:default]
        json_hash[column[:name]] = value if value
      end
      return nil if json_hash.empty?
      json_hash.to_json
    end


    def serialize_to_csv ( event )
      return nil unless @fields_map && !@fields_map.empty?

      csv_array = [  ]
      @fields_map.each do |column|
        value = event[column[:name]] || column[:default] || @csv_default_value
        type = (column[:type] || value.class.name).downcase.to_sym
        csv_array << ( [:hash, :array, :json, :dynamic, :object].include?( type ) ? value.to_json : value )
      end
      return nil if csv_array.empty?
      csv_array.to_csv( :col_sep => @csv_separator )
    end


    def find_blob
      min_blob = @active_blobs[0]
      @active_blobs.each do |blob|
        return blob if 0 == blob.queue_size
        min_blob = blob if blob.queue_size < min_blob.queue_size
      end
      @active_blobs << ( min_blob = Blob.new( self, @active_blobs.length + 1 ) ) if min_blob.queue_size > 2 && @active_blobs.length < 40
      min_blob
    end


    def set_table_properties ( configuration )
      table_properties = configuration[:table_ids_properties][@table_id]

      @blob_max_delay = ( table_properties[:blob_max_delay] if table_properties ) || configuration[:blob_max_delay]
      @event_separator = ( table_properties[:event_separator] if table_properties ) || configuration[:event_separator]

      if table_properties
        @data_field = table_properties[:data_field]
        @fields_map = table_properties[:fields_map]
        @csv_default_value = table_properties[:csv_default_value] || configuration[:csv_default_value]
        @csv_separator = table_properties[:csv_separator] || configuration[:csv_separator]
      end
    end


    def set_event_format_ext ( configuration )
      table_properties = configuration[:table_ids_properties][@table_id]
      @event_format_ext = ( table_properties[:ext] if table_properties ) || EXT_EVENT_FORMAT_JSON
    end

  end
end
