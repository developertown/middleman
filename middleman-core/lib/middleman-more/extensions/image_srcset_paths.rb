# Automatic Image Sizes extension
class Middleman::Extensions::ImageSrcsetPaths < ::Middleman::Extension
  def initialize(app, options_hash={}, &block)
    super
  end

  helpers do
    # Override default image_tag helper to automatically create paths for srcset property
    # for responsive images
    # the following:
    # image_tage 'pic_1980.jpg', srcset: 'pic_640.jpg 640w, pic_1024.jpg 1024w, pic_1980.jpg 1980w'
    # will generate...
    # <img src="/images/ants_1980.jpg" srcset="/images/pic_640.jpg 640w, /images/pic_1024.jpg 1024w, /images/pic_1980.jpg 1980w">

    # @param [String] path
    # @param [Hash] params
    # @return [String]
    def image_tag(path, params={})
      params.symbolize_keys!
      
      if params.key?(:srcset)
        images = params[:srcset].split(',').map {|size| (size.include?('//') ? size : asset_url("images/#{size.strip}")) }
        params[:srcset] = images.join(', ')
      end

      super(path, params)
    end
  end
end
