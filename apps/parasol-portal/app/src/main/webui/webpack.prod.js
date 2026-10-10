/* eslint-disable @typescript-eslint/no-var-requires */

const { merge } = require('webpack-merge');
const common = require('./webpack.common.js');
const { stylePaths } = require('./stylePaths.js');
const MiniCssExtractPlugin = require('mini-css-extract-plugin');
const CssMinimizerPlugin = require('css-minimizer-webpack-plugin');
const TerserJSPlugin = require('terser-webpack-plugin');

module.exports = merge(common('production'), {
  mode: 'production',
  devtool: 'source-map',
  // Content-hashed bundle names: the static handler serves them "immutable", which is only correct
  // when the filename changes with the content. Without the hash, returning browsers keep a stale
  // bundle for a day and never see UI changes. HtmlWebpackPlugin injects the hashed names.
  output: {
    filename: '[name].[contenthash].bundle.js',
  },
  optimization: {
    minimizer: [
      new TerserJSPlugin({}),
      new CssMinimizerPlugin({
        minimizerOptions: {
          preset: ['default', { mergeLonghand: false }],
        },
      }),
    ],
  },
  plugins: [
    new MiniCssExtractPlugin({
      filename: '[name].css',
      chunkFilename: '[name].bundle.css',
    }),
  ],
  module: {
    rules: [
      {
        test: /\.css$/,
        include: [...stylePaths],
        use: [MiniCssExtractPlugin.loader, 'css-loader'],
      },
    ],
  },
});
